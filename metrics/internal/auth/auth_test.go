package auth

import (
	"crypto/rand"
	"crypto/rsa"
	"encoding/base64"
	"encoding/json"
	"math/big"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/golang-jwt/jwt/v5"
)

const (
	tenant   = "11111111-2222-3333-4444-555555555555"
	audience = "api://pullpicket-metrics"
	clientID = "6f1c0000-0000-0000-0000-000000000000"
	kid      = "key-1"
)

// fakeEntra serves a JWKS document for the keys it holds and signs tokens
// with them.
type fakeEntra struct {
	t       *testing.T
	server  *httptest.Server
	mu      sync.Mutex
	keys    map[string]*rsa.PrivateKey
	fetches atomic.Int32
	down    atomic.Bool
}

func newFakeEntra(t *testing.T) *fakeEntra {
	t.Helper()
	f := &fakeEntra{t: t, keys: map[string]*rsa.PrivateKey{kid: newRSAKey(t)}}
	f.server = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/"+tenant+"/discovery/v2.0/keys" {
			http.NotFound(w, r)
			return
		}
		f.fetches.Add(1)
		if f.down.Load() {
			http.Error(w, "unavailable", http.StatusServiceUnavailable)
			return
		}
		type jwk struct {
			Kty string `json:"kty"`
			Use string `json:"use"`
			Kid string `json:"kid"`
			N   string `json:"n"`
			E   string `json:"e"`
		}
		var doc struct {
			Keys []jwk `json:"keys"`
		}
		f.mu.Lock()
		defer f.mu.Unlock()
		for id, k := range f.keys {
			doc.Keys = append(doc.Keys, jwk{
				Kty: "RSA", Use: "sig", Kid: id,
				N: base64.RawURLEncoding.EncodeToString(k.N.Bytes()),
				E: base64.RawURLEncoding.EncodeToString(big.NewInt(int64(k.E)).Bytes()),
			})
		}
		_ = json.NewEncoder(w).Encode(doc)
	}))
	t.Cleanup(f.server.Close)
	return f
}

func newRSAKey(t *testing.T) *rsa.PrivateKey {
	t.Helper()
	k, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		t.Fatal(err)
	}
	return k
}

func (f *fakeEntra) issuer() string { return f.server.URL + "/" + tenant + "/v2.0" }

// claims returns a valid set of claims for a token that should be accepted.
func (f *fakeEntra) claims(now time.Time) jwt.MapClaims {
	return jwt.MapClaims{
		"iss":   f.issuer(),
		"aud":   audience,
		"tid":   tenant,
		"oid":   "pipeline-oid",
		"azp":   "pipeline-app",
		"roles": []any{WriteRole},
		"iat":   now.Add(-time.Minute).Unix(),
		"nbf":   now.Add(-time.Minute).Unix(),
		"exp":   now.Add(time.Hour).Unix(),
	}
}

func (f *fakeEntra) sign(claims jwt.MapClaims, keyID string) string {
	f.t.Helper()
	tok := jwt.NewWithClaims(jwt.SigningMethodRS256, claims)
	if keyID != "" {
		tok.Header["kid"] = keyID
	}
	f.mu.Lock()
	key := f.keys[keyID]
	if key == nil {
		key = f.keys[kid]
	}
	f.mu.Unlock()
	s, err := tok.SignedString(key)
	if err != nil {
		f.t.Fatal(err)
	}
	return s
}

func (f *fakeEntra) config(mode Mode, now func() time.Time) Config {
	return Config{
		Mode:      mode,
		TenantID:  tenant,
		Audiences: []string{audience, clientID},
		APIKey:    testKey,
		Authority: f.server.URL,
		Now:       now,
	}
}

var testKey = strings.Repeat("k", MinKeyLength)

type request struct {
	bearer string // full Authorization header value
	apiKey string
}

func call(t *testing.T, mw func(http.Handler) http.Handler, req request) *httptest.ResponseRecorder {
	t.Helper()
	ok := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { w.WriteHeader(http.StatusCreated) })
	r := httptest.NewRequest(http.MethodPost, "/events", strings.NewReader(`{}`))
	if req.bearer != "" {
		r.Header.Set("Authorization", req.bearer)
	}
	if req.apiKey != "" {
		r.Header.Set("X-Api-Key", req.apiKey)
	}
	w := httptest.NewRecorder()
	mw(ok).ServeHTTP(w, r)
	return w
}

func TestParseMode(t *testing.T) {
	tests := []struct {
		raw     string
		want    string
		wantErr bool
	}{
		{"", "", true},
		{"   ", "", true},
		{"entra", "entra", false},
		{"key", "key", false},
		{"entra,key", "entra,key", false},
		{"KEY, Entra", "entra,key", false},
		{"none", "none", false},
		{"none,entra", "", true},
		{"basic", "", true},
		{"entra,", "", true},
	}
	for _, tt := range tests {
		m, err := ParseMode(tt.raw)
		if (err != nil) != tt.wantErr {
			t.Errorf("%q: err = %v, wantErr %v", tt.raw, err, tt.wantErr)
			continue
		}
		if m.String() != tt.want {
			t.Errorf("%q: mode = %q, want %q", tt.raw, m, tt.want)
		}
	}
}

// TestMiddleware is the table of every auth path (plan item M13).
func TestMiddleware(t *testing.T) {
	f := newFakeEntra(t)
	now := time.Now()
	clock := func() time.Time { return now }
	bearer := func(edit func(jwt.MapClaims)) string {
		c := f.claims(now)
		if edit != nil {
			edit(c)
		}
		return "Bearer " + f.sign(c, kid)
	}
	otherKey := newRSAKey(t)
	forged := func() string {
		tok := jwt.NewWithClaims(jwt.SigningMethodRS256, f.claims(now))
		tok.Header["kid"] = kid
		s, _ := tok.SignedString(otherKey)
		return "Bearer " + s
	}
	hs256 := func() string {
		tok := jwt.NewWithClaims(jwt.SigningMethodHS256, f.claims(now))
		tok.Header["kid"] = kid
		s, _ := tok.SignedString([]byte("secret"))
		return "Bearer " + s
	}
	unsigned := func() string {
		tok := jwt.NewWithClaims(jwt.SigningMethodNone, f.claims(now))
		tok.Header["kid"] = kid
		s, _ := tok.SignedString(jwt.UnsafeAllowNoneSignatureType)
		return "Bearer " + s
	}

	entra := Mode{Entra: true}
	key := Mode{Key: true}
	both := Mode{Entra: true, Key: true}

	tests := []struct {
		name       string
		mode       Mode
		principals []string
		req        request
		want       int
		wantBody   string // substring
	}{
		// Entra
		{name: "entra: valid token with role", mode: entra, req: request{bearer: bearer(nil)}, want: 201},
		{name: "entra: lowercase bearer scheme", mode: entra, req: request{bearer: strings.Replace(bearer(nil), "Bearer", "bearer", 1)}, want: 201},
		{name: "entra: client id as audience (v2 token)", mode: entra, req: request{bearer: bearer(func(c jwt.MapClaims) { c["aud"] = clientID })}, want: 201},
		{name: "entra: v1 issuer", mode: entra, req: request{bearer: bearer(func(c jwt.MapClaims) { c["iss"] = "https://sts.windows.net/" + tenant + "/" })}, want: 201},
		{name: "entra: no credentials", mode: entra, req: request{}, want: 401, wantBody: "credentials required"},
		{name: "entra: expired", mode: entra, req: request{bearer: bearer(func(c jwt.MapClaims) { c["exp"] = now.Add(-10 * time.Minute).Unix() })}, want: 401, wantBody: "invalid credentials"},
		{name: "entra: expired within leeway", mode: entra, req: request{bearer: bearer(func(c jwt.MapClaims) { c["exp"] = now.Add(-time.Minute).Unix() })}, want: 201},
		{name: "entra: no expiry", mode: entra, req: request{bearer: bearer(func(c jwt.MapClaims) { delete(c, "exp") })}, want: 401},
		{name: "entra: not yet valid", mode: entra, req: request{bearer: bearer(func(c jwt.MapClaims) { c["nbf"] = now.Add(10 * time.Minute).Unix() })}, want: 401},
		{name: "entra: wrong audience", mode: entra, req: request{bearer: bearer(func(c jwt.MapClaims) { c["aud"] = "https://management.azure.com" })}, want: 401},
		{name: "entra: wrong issuer", mode: entra, req: request{bearer: bearer(func(c jwt.MapClaims) { c["iss"] = "https://login.microsoftonline.com/other/v2.0" })}, want: 401},
		{name: "entra: other tenant", mode: entra, req: request{bearer: bearer(func(c jwt.MapClaims) { c["tid"] = "99999999-0000-0000-0000-000000000000" })}, want: 401},
		{name: "entra: missing role", mode: entra, req: request{bearer: bearer(func(c jwt.MapClaims) { delete(c, "roles") })}, want: 403, wantBody: WriteRole},
		{name: "entra: other role only", mode: entra, req: request{bearer: bearer(func(c jwt.MapClaims) { c["roles"] = []any{"Events.Read"} })}, want: 403},
		{name: "entra: no role but allowlisted oid", mode: entra, principals: []string{"PIPELINE-OID"}, req: request{bearer: bearer(func(c jwt.MapClaims) { delete(c, "roles") })}, want: 201},
		{name: "entra: no role but allowlisted client app", mode: entra, principals: []string{"pipeline-app"}, req: request{bearer: bearer(func(c jwt.MapClaims) { delete(c, "roles") })}, want: 201},
		{name: "entra: no role, not allowlisted", mode: entra, principals: []string{"someone-else"}, req: request{bearer: bearer(func(c jwt.MapClaims) { delete(c, "roles") })}, want: 403},
		{name: "entra: signed by another key", mode: entra, req: request{bearer: forged()}, want: 401},
		{name: "entra: HS256", mode: entra, req: request{bearer: hs256()}, want: 401},
		{name: "entra: alg none", mode: entra, req: request{bearer: unsigned()}, want: 401},
		{name: "entra: unknown kid", mode: entra, req: request{bearer: "Bearer " + f.sign(f.claims(now), "nope")}, want: 401},
		{name: "entra: not a JWT", mode: entra, req: request{bearer: "Bearer not-a-token"}, want: 401},
		{name: "entra: basic scheme", mode: entra, req: request{bearer: "Basic dXNlcjpwYXNz"}, want: 401},
		{name: "entra: empty bearer", mode: entra, req: request{bearer: "Bearer "}, want: 401},
		{name: "entra: API key is not accepted", mode: entra, req: request{apiKey: testKey}, want: 401, wantBody: "credentials required"},

		// Key
		{name: "key: valid", mode: key, req: request{apiKey: testKey}, want: 201},
		{name: "key: wrong key", mode: key, req: request{apiKey: strings.Repeat("x", MinKeyLength)}, want: 401, wantBody: "invalid credentials"},
		{name: "key: prefix of the key", mode: key, req: request{apiKey: testKey[:10]}, want: 401},
		{name: "key: key plus extra", mode: key, req: request{apiKey: testKey + "x"}, want: 401},
		{name: "key: missing", mode: key, req: request{}, want: 401, wantBody: "X-Api-Key"},
		{name: "key: a token is not accepted", mode: key, req: request{bearer: bearer(nil)}, want: 401},

		// Both
		{name: "both: token", mode: both, req: request{bearer: bearer(nil)}, want: 201},
		{name: "both: key", mode: both, req: request{apiKey: testKey}, want: 201},
		{name: "both: bad token, good key", mode: both, req: request{bearer: forged(), apiKey: testKey}, want: 201},
		{name: "both: good token, bad key", mode: both, req: request{bearer: bearer(nil), apiKey: "wrong"}, want: 201},
		{name: "both: neither", mode: both, req: request{}, want: 401, wantBody: "Bearer) or an API key"},
		{name: "both: bad token, bad key", mode: both, req: request{bearer: forged(), apiKey: "wrong"}, want: 401},
		{name: "both: token without role, no key", mode: both, req: request{bearer: bearer(func(c jwt.MapClaims) { delete(c, "roles") })}, want: 403},

		// None and unconfigured
		{name: "none: no credentials", mode: Mode{None: true}, req: request{}, want: 201},
		{name: "unconfigured: refuses everything", mode: Mode{}, req: request{apiKey: testKey, bearer: bearer(nil)}, want: 503},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			cfg := f.config(tt.mode, clock)
			cfg.AllowedPrincipals = tt.principals
			mw, err := New(cfg)
			if err != nil {
				t.Fatal(err)
			}
			w := call(t, mw, tt.req)
			if w.Code != tt.want {
				t.Fatalf("status = %d, want %d (body %s)", w.Code, tt.want, w.Body)
			}
			if tt.wantBody != "" && !strings.Contains(w.Body.String(), tt.wantBody) {
				t.Errorf("body %q does not contain %q", w.Body, tt.wantBody)
			}
			if w.Code >= 400 && w.Header().Get("Content-Type") != "application/json" {
				t.Errorf("content type = %q", w.Header().Get("Content-Type"))
			}
			challenge := w.Header().Get("WWW-Authenticate")
			if w.Code == 401 && tt.mode.Entra != strings.HasPrefix(challenge, "Bearer") {
				t.Errorf("WWW-Authenticate = %q for mode %s", challenge, tt.mode)
			}
		})
	}
}

func TestNewRejectsIncompleteConfig(t *testing.T) {
	for _, cfg := range []Config{
		{Mode: Mode{Key: true}},
		{Mode: Mode{Key: true}, APIKey: "short"},
		{Mode: Mode{Entra: true}, Audiences: []string{audience}},
		{Mode: Mode{Entra: true}, TenantID: tenant},
	} {
		if _, err := New(cfg); err == nil {
			t.Errorf("New(%+v) accepted an incomplete config", cfg)
		}
	}
}

// TestSigningKeys: keys are fetched once and cached, a new key id triggers
// one early refresh (key rollover), made-up key ids cannot force a fetch per
// request, and an Entra outage keeps the cached keys working.
func TestSigningKeys(t *testing.T) {
	f := newFakeEntra(t)
	now := time.Now()
	clock := func() time.Time { return now }
	mw, err := New(f.config(Mode{Entra: true}, clock))
	if err != nil {
		t.Fatal(err)
	}
	send := func(keyID string) int {
		t.Helper()
		c := f.claims(now)
		return call(t, mw, request{bearer: "Bearer " + f.sign(c, keyID)}).Code
	}

	for range 3 {
		if code := send(kid); code != 201 {
			t.Fatalf("status = %d", code)
		}
	}
	if n := f.fetches.Load(); n != 1 {
		t.Errorf("fetches after 3 tokens = %d, want 1 (cached)", n)
	}

	// Rollover: Entra publishes key-2; a token signed with it triggers a
	// refresh once the cooldown has passed since the last fetch.
	k2 := newRSAKey(t)
	f.mu.Lock()
	f.keys["key-2"] = k2
	f.mu.Unlock()
	if code := send("key-2"); code != 401 {
		t.Errorf("new key within the cooldown: status = %d, want 401", code)
	}
	now = now.Add(keysRefreshCooldown)
	if code := send("key-2"); code != 201 {
		t.Errorf("new key after the cooldown: status = %d, want 201", code)
	}
	if n := f.fetches.Load(); n != 2 {
		t.Errorf("fetches after rollover = %d, want 2", n)
	}

	// Made-up kids: at most one fetch per cooldown.
	for range 5 {
		if code := send("made-up"); code != 401 {
			t.Errorf("made-up kid: status = %d", code)
		}
	}
	if n := f.fetches.Load(); n != 2 {
		t.Errorf("fetches after made-up kids = %d, want 2", n)
	}

	// Outage after the keys go stale: the cached keys keep working.
	f.down.Store(true)
	now = now.Add(keysMaxAge + time.Minute)
	if code := send(kid); code != 201 {
		t.Errorf("during an outage: status = %d, want 201 from the cached keys", code)
	}
	if n := f.fetches.Load(); n != 3 {
		t.Errorf("fetches during outage = %d, want 3 (one refresh attempt)", n)
	}
}

// TestSigningKeysUnavailable: with Entra unreachable from the start, tokens
// are refused (never accepted unchecked), and the next attempt waits a little.
func TestSigningKeysUnavailable(t *testing.T) {
	f := newFakeEntra(t)
	f.down.Store(true)
	now := time.Now()
	clock := func() time.Time { return now }
	mw, err := New(f.config(Mode{Entra: true}, clock))
	if err != nil {
		t.Fatal(err)
	}
	tok := "Bearer " + f.sign(f.claims(now), kid)
	for range 3 {
		if code := call(t, mw, request{bearer: tok}).Code; code != 401 {
			t.Fatalf("status = %d, want 401", code)
		}
	}
	if n := f.fetches.Load(); n != 1 {
		t.Errorf("fetches = %d, want 1", n)
	}
	f.down.Store(false)
	now = now.Add(keysRetryWithoutKeys)
	if code := call(t, mw, request{bearer: tok}).Code; code != 201 {
		t.Errorf("after Entra recovers: status = %d, want 201", code)
	}
}
