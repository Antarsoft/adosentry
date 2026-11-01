package auth

import (
	"context"
	"crypto/rsa"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"math/big"
	"net/http"
	"slices"
	"strings"
	"sync"
	"time"

	"github.com/golang-jwt/jwt/v5"
)

const (
	defaultAuthority = "https://login.microsoftonline.com"
	// keysMaxAge is how long fetched signing keys are trusted before a
	// refresh. Entra rolls keys with weeks of overlap, so a day is plenty.
	keysMaxAge = 24 * time.Hour
	// keysRefreshCooldown limits refetches triggered by an unknown key id,
	// so a flood of tokens with made-up kids cannot hammer Entra.
	keysRefreshCooldown = 5 * time.Minute
	// keysRetryWithoutKeys is the shorter wait between attempts while no
	// keys have ever been fetched (Entra unreachable at startup).
	keysRetryWithoutKeys = 10 * time.Second
	// clockLeeway absorbs clock drift between Entra and this host.
	clockLeeway = 2 * time.Minute
	// maxKeysBytes caps the signing-key document.
	maxKeysBytes = 1 << 20
)

// entraValidator checks Entra ID access tokens for one tenant.
type entraValidator struct {
	tenantID          string
	issuers           []string
	audiences         []string
	allowedPrincipals []string
	keys              *keySet
	now               func() time.Time
}

func newEntraValidator(cfg Config) *entraValidator {
	authority := strings.TrimRight(cfg.Authority, "/")
	if authority == "" {
		authority = defaultAuthority
	}
	client := cfg.HTTPClient
	if client == nil {
		client = &http.Client{Timeout: 10 * time.Second}
	}
	now := cfg.Now
	if now == nil {
		now = time.Now
	}
	return &entraValidator{
		tenantID: cfg.TenantID,
		// v2.0 tokens name the sign-in host; v1.0 tokens (the default for an
		// app registration that leaves accessTokenAcceptedVersion unset, and
		// what Get-AzAccessToken usually returns) name sts.windows.net.
		issuers: []string{
			authority + "/" + cfg.TenantID + "/v2.0",
			"https://sts.windows.net/" + cfg.TenantID + "/",
		},
		audiences:         cfg.Audiences,
		allowedPrincipals: cfg.AllowedPrincipals,
		keys: &keySet{
			// This endpoint serves the keys for both v1.0 and v2.0 tokens.
			url:    authority + "/" + cfg.TenantID + "/discovery/v2.0/keys",
			client: client,
			now:    now,
		},
		now: now,
	}
}

func (v *entraValidator) check(ctx context.Context, raw string) (outcome, string) {
	parser := jwt.NewParser(
		jwt.WithValidMethods([]string{"RS256"}),
		jwt.WithAudience(v.audiences...),
		jwt.WithExpirationRequired(),
		jwt.WithLeeway(clockLeeway),
		jwt.WithTimeFunc(v.now),
	)
	claims := jwt.MapClaims{}
	_, err := parser.ParseWithClaims(raw, claims, func(t *jwt.Token) (any, error) {
		kid, _ := t.Header["kid"].(string)
		if kid == "" {
			return nil, errors.New("token has no kid header")
		}
		return v.keys.get(ctx, kid)
	})
	if err != nil {
		return rejected, err.Error()
	}

	iss, _ := claims["iss"].(string)
	if !slices.Contains(v.issuers, iss) {
		return rejected, fmt.Sprintf("issuer %q is not this tenant's", iss)
	}
	if tid, _ := claims["tid"].(string); tid != "" && !strings.EqualFold(tid, v.tenantID) {
		return rejected, fmt.Sprintf("tenant %q is not %q", tid, v.tenantID)
	}

	if hasRole(claims, WriteRole) {
		return accepted, ""
	}
	for _, claim := range []string{"oid", "azp", "appid"} {
		if id, _ := claims[claim].(string); id != "" && containsFold(v.allowedPrincipals, id) {
			return accepted, ""
		}
	}
	oid, _ := claims["oid"].(string)
	return forbidden, fmt.Sprintf("principal %q has no %s role and is not in ENTRA_ALLOWED_PRINCIPALS", oid, WriteRole)
}

func hasRole(claims jwt.MapClaims, role string) bool {
	roles, _ := claims["roles"].([]any)
	for _, r := range roles {
		if s, _ := r.(string); s == role {
			return true
		}
	}
	return false
}

func containsFold(list []string, s string) bool {
	return slices.ContainsFunc(list, func(item string) bool { return strings.EqualFold(item, s) })
}

// keySet caches the tenant's token-signing keys. It refreshes them once a
// day, and early (at most every keysRefreshCooldown) when a token names a
// key it has not seen, which is how a key rollover shows up.
type keySet struct {
	url    string
	client *http.Client
	now    func() time.Time

	mu          sync.Mutex
	keys        map[string]*rsa.PublicKey
	fetchedAt   time.Time
	lastAttempt time.Time
}

func (s *keySet) get(ctx context.Context, kid string) (*rsa.PublicKey, error) {
	s.mu.Lock()
	defer s.mu.Unlock()

	now := s.now()
	key, known := s.keys[kid]
	stale := now.Sub(s.fetchedAt) > keysMaxAge
	if known && !stale {
		return key, nil
	}
	cooldown := keysRefreshCooldown
	if s.keys == nil {
		cooldown = keysRetryWithoutKeys
	}
	if s.lastAttempt.IsZero() || now.Sub(s.lastAttempt) >= cooldown {
		s.lastAttempt = now
		keys, err := s.fetch(ctx)
		switch {
		case err == nil:
			s.keys, s.fetchedAt = keys, now
		case s.keys == nil:
			return nil, fmt.Errorf("fetching signing keys: %w", err)
		default:
			// Keep the old keys rather than refuse every token while Entra
			// is unreachable.
			log.Printf("auth: refreshing signing keys failed, keeping the cached ones: %v", err)
		}
		key, known = s.keys[kid]
	}
	if s.keys == nil {
		return nil, errors.New("signing keys are not available yet")
	}
	if !known {
		return nil, fmt.Errorf("unknown signing key %q", kid)
	}
	return key, nil
}

func (s *keySet) fetch(ctx context.Context) (map[string]*rsa.PublicKey, error) {
	// The request's own context would let one cancelled request fail the
	// fetch for everyone waiting on the lock; the client timeout bounds it.
	req, err := http.NewRequestWithContext(context.WithoutCancel(ctx), http.MethodGet, s.url, nil)
	if err != nil {
		return nil, err
	}
	resp, err := s.client.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("GET %s: %s", s.url, resp.Status)
	}
	var doc struct {
		Keys []struct {
			Kty string `json:"kty"`
			Use string `json:"use"`
			Kid string `json:"kid"`
			N   string `json:"n"`
			E   string `json:"e"`
		} `json:"keys"`
	}
	if err := json.NewDecoder(io.LimitReader(resp.Body, maxKeysBytes)).Decode(&doc); err != nil {
		return nil, fmt.Errorf("decoding %s: %w", s.url, err)
	}
	keys := map[string]*rsa.PublicKey{}
	for _, k := range doc.Keys {
		if k.Kty != "RSA" || (k.Use != "" && k.Use != "sig") || k.Kid == "" {
			continue
		}
		pub, err := rsaKey(k.N, k.E)
		if err != nil {
			log.Printf("auth: skipping signing key %q: %v", k.Kid, err)
			continue
		}
		keys[k.Kid] = pub
	}
	if len(keys) == 0 {
		return nil, fmt.Errorf("%s has no usable RSA signing keys", s.url)
	}
	return keys, nil
}

func rsaKey(n, e string) (*rsa.PublicKey, error) {
	nb, err := base64.RawURLEncoding.DecodeString(n)
	if err != nil {
		return nil, fmt.Errorf("modulus: %w", err)
	}
	eb, err := base64.RawURLEncoding.DecodeString(e)
	if err != nil {
		return nil, fmt.Errorf("exponent: %w", err)
	}
	exp := new(big.Int).SetBytes(eb)
	if len(nb) < 256 || !exp.IsInt64() || exp.Int64() < 3 || exp.Int64() > 1<<31-1 {
		return nil, errors.New("not a usable RSA key (at least 2048 bits, sane exponent)")
	}
	return &rsa.PublicKey{N: new(big.Int).SetBytes(nb), E: int(exp.Int64())}, nil
}
