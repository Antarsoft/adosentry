// Package auth guards the write endpoint (POST /events).
//
// A sender proves itself in one of two ways, chosen with AUTH_MODE:
//
//   - entra: a Microsoft Entra ID access token in "Authorization: Bearer ...".
//     The signature is checked against the tenant's published keys, then the
//     issuer, audience, expiry and not-before. The token must also carry the
//     Events.Write app role, or come from a principal (object id or client
//     app id) on the ENTRA_ALLOWED_PRINCIPALS list. Without that last check
//     any identity in the tenant could get a token for the API and write.
//   - key: a shared secret in "X-Api-Key", compared in constant time.
//
// "entra,key" accepts either. "none" accepts anything and exists for local
// development only. There is no default: an unset AUTH_MODE stops the
// service at startup instead of quietly accepting writes.
package auth

import (
	"crypto/sha256"
	"crypto/subtle"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"net/http"
	"strings"
	"time"
)

// Mode is the set of credentials the service accepts.
type Mode struct {
	Entra bool
	Key   bool
	// None turns authentication off. It is never combined with the others.
	None bool
}

// String gives the mode back in AUTH_MODE syntax.
func (m Mode) String() string {
	switch {
	case m.None:
		return "none"
	case m.Entra && m.Key:
		return "entra,key"
	case m.Entra:
		return "entra"
	case m.Key:
		return "key"
	default:
		return ""
	}
}

// ParseMode reads AUTH_MODE: "entra", "key", "entra,key" (in either order)
// or "none". Empty is an error, so a missing setting never means "open".
func ParseMode(raw string) (Mode, error) {
	var m Mode
	raw = strings.TrimSpace(raw)
	if raw == "" {
		return Mode{}, errors.New(`AUTH_MODE is required: set it to "entra", "key", "entra,key" or, for local development only, "none"`)
	}
	for _, part := range strings.Split(raw, ",") {
		switch strings.ToLower(strings.TrimSpace(part)) {
		case "entra":
			m.Entra = true
		case "key":
			m.Key = true
		case "none":
			m.None = true
		default:
			return Mode{}, fmt.Errorf(`AUTH_MODE: unknown value %q; use "entra", "key", "entra,key" or "none"`, strings.TrimSpace(part))
		}
	}
	if m.None && (m.Entra || m.Key) {
		return Mode{}, errors.New(`AUTH_MODE: "none" cannot be combined with "entra" or "key"`)
	}
	return m, nil
}

// MinKeyLength is the shortest METRICS_API_KEY accepted. 32 characters of a
// generated key (for example `openssl rand -base64 32`) cannot be guessed.
const MinKeyLength = 32

// Config is everything the middleware needs. config.Load fills it from the
// environment and checks that each mode has its settings.
type Config struct {
	Mode Mode
	// Entra settings, used when Mode.Entra.
	TenantID string
	// Audiences are the accepted "aud" values: the API's application ID URI
	// (api://...) and usually its client id too, because Entra puts the
	// client id in v2 tokens and the URI in v1 tokens.
	Audiences []string
	// AllowedPrincipals are object ids (oid) or client app ids (azp/appid)
	// allowed to write without the Events.Write role.
	AllowedPrincipals []string
	// APIKey is the shared secret, used when Mode.Key.
	APIKey string
	// Authority is the sign-in host; empty means
	// https://login.microsoftonline.com. Tests point it at a fake.
	Authority string
	// HTTPClient fetches the signing keys; nil means a client with a
	// 10-second timeout.
	HTTPClient *http.Client
	// Now is the clock; nil means time.Now.
	Now func() time.Time
}

// WriteRole is the app role a token must carry to post events.
const WriteRole = "Events.Write"

// Validate reports a setting the chosen mode needs but does not have.
func (c Config) Validate() error {
	var problems []string
	if c.Mode.Entra {
		if c.TenantID == "" {
			problems = append(problems, "ENTRA_TENANT_ID is required when AUTH_MODE includes entra")
		}
		if len(c.Audiences) == 0 {
			problems = append(problems, "ENTRA_AUDIENCE is required when AUTH_MODE includes entra")
		}
	}
	if c.Mode.Key {
		switch {
		case c.APIKey == "":
			problems = append(problems, "METRICS_API_KEY is required when AUTH_MODE includes key")
		case len(c.APIKey) < MinKeyLength:
			problems = append(problems, fmt.Sprintf("METRICS_API_KEY must be at least %d characters (try: openssl rand -base64 32)", MinKeyLength))
		}
	}
	if len(problems) > 0 {
		return errors.New(strings.Join(problems, "; "))
	}
	return nil
}

// New returns middleware that lets a request through only with a valid
// credential for the configured mode. A zero Config (no mode at all) denies
// every request, so forgetting to configure auth never opens the endpoint.
func New(cfg Config) (func(http.Handler) http.Handler, error) {
	if cfg.Mode.None {
		return func(h http.Handler) http.Handler { return h }, nil
	}
	if !cfg.Mode.Entra && !cfg.Mode.Key {
		return func(http.Handler) http.Handler {
			return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				writeError(w, http.StatusServiceUnavailable, "authentication is not configured", "")
			})
		}, nil
	}
	if err := cfg.Validate(); err != nil {
		return nil, err
	}
	g := &guard{mode: cfg.Mode}
	if cfg.Mode.Entra {
		g.entra = newEntraValidator(cfg)
	}
	if cfg.Mode.Key {
		sum := sha256.Sum256([]byte(cfg.APIKey))
		g.keyHash = sum[:]
	}
	return g.wrap, nil
}

type guard struct {
	mode    Mode
	entra   *entraValidator
	keyHash []byte
}

// outcome of checking one credential.
type outcome int

const (
	absent    outcome = iota // the request did not offer this credential
	accepted                 // valid
	rejected                 // offered but invalid: 401
	forbidden                // a valid token without the role: 403
)

func (g *guard) wrap(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		results := make([]outcome, 0, 2)
		if g.entra != nil {
			res, reason := g.checkBearer(r)
			if res == accepted {
				next.ServeHTTP(w, r)
				return
			}
			if res != absent {
				log.Printf("auth: bearer token refused: %s", reason)
			}
			results = append(results, res)
		}
		if g.keyHash != nil {
			res := g.checkKey(r)
			if res == accepted {
				next.ServeHTTP(w, r)
				return
			}
			if res == rejected {
				log.Printf("auth: X-Api-Key refused")
			}
			results = append(results, res)
		}

		for _, res := range results {
			if res == forbidden {
				writeError(w, http.StatusForbidden, "the token does not carry the "+WriteRole+" app role", "")
				return
			}
		}
		for _, res := range results {
			if res == rejected {
				writeError(w, http.StatusUnauthorized, "invalid credentials", g.challenge(`Bearer error="invalid_token"`))
				return
			}
		}
		writeError(w, http.StatusUnauthorized, "credentials required: "+g.expected(), g.challenge("Bearer"))
	})
}

// challenge is the WWW-Authenticate value for a 401: only bearer tokens
// have a standard challenge, so key-only mode sends none.
func (g *guard) challenge(v string) string {
	if g.entra == nil {
		return ""
	}
	return v
}

func (g *guard) expected() string {
	switch {
	case g.entra != nil && g.keyHash != nil:
		return "send an Entra access token (Authorization: Bearer) or an API key (X-Api-Key)"
	case g.entra != nil:
		return "send an Entra access token (Authorization: Bearer)"
	default:
		return "send an API key (X-Api-Key)"
	}
}

func (g *guard) checkBearer(r *http.Request) (outcome, string) {
	h := r.Header.Get("Authorization")
	if h == "" {
		return absent, ""
	}
	scheme, token, ok := strings.Cut(h, " ")
	if !ok || !strings.EqualFold(scheme, "Bearer") || strings.TrimSpace(token) == "" {
		return rejected, "Authorization header is not a bearer token"
	}
	return g.entra.check(r.Context(), strings.TrimSpace(token))
}

func (g *guard) checkKey(r *http.Request) outcome {
	key := r.Header.Get("X-Api-Key")
	if key == "" {
		return absent
	}
	// Hashing both sides first makes the comparison constant-time in the
	// key's length too, not only its content.
	sum := sha256.Sum256([]byte(key))
	if subtle.ConstantTimeCompare(sum[:], g.keyHash) == 1 {
		return accepted
	}
	return rejected
}

// writeError answers with a JSON error. msg is always one of the fixed
// strings above, never request data, so a refusal reveals nothing about why
// a token failed; the reason goes to the log instead.
func writeError(w http.ResponseWriter, status int, msg, wwwAuthenticate string) {
	if wwwAuthenticate != "" {
		w.Header().Set("WWW-Authenticate", wwwAuthenticate)
	}
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(map[string]string{"error": msg})
}
