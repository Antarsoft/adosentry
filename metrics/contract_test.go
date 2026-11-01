package main

// Characterisation tests (plan item M1). They pin the HTTP contract of the
// metrics API as it behaves today: status codes, bodies, headers, the stored
// event shape, and the full /metrics/summary response. They drive the real
// router and the real azcosmos client against an in-memory Cosmos fake, so
// they keep passing unchanged while the code is reorganised underneath.
//
// Regenerate the summary golden file after an intended contract change with:
//
//	go test -run TestSummaryGolden -update .

import (
	"bytes"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"regexp"
	"slices"
	"sort"
	"strings"
	"testing"
	"time"

	"github.com/antarsoft/adosentry/metrics/internal/auth"
	"github.com/antarsoft/adosentry/metrics/internal/config"
	"github.com/antarsoft/adosentry/metrics/internal/cosmostest"
	"github.com/antarsoft/adosentry/metrics/internal/storage"
)

var update = flag.Bool("update", false, "rewrite golden files in testdata/")

const feature = "ai-code-review"

// newTestAPI starts the API wired to a fresh Cosmos fake.
func newTestAPI(t *testing.T) (*httptest.Server, *cosmostest.Server) {
	t.Helper()
	return newTestAPIWith(t, nil)
}

// newTestAPIWith lets a test adjust the configuration first.
func newTestAPIWith(t *testing.T, adjust func(*config.Config)) (*httptest.Server, *cosmostest.Server) {
	t.Helper()
	fake := cosmostest.New(t)
	cfg := config.Config{
		Cosmos: storage.CosmosConfig{Endpoint: fake.URL, Key: "ZHVtbXk=", Database: "db", Container: "events"},
		// The contract tests are about the API, not auth; TestEventsAuth
		// covers the wiring and the auth package covers the rest.
		Auth: auth.Config{Mode: auth.Mode{None: true}},
	}
	if adjust != nil {
		adjust(&cfg)
	}
	handler, err := newHandler(cfg)
	if err != nil {
		t.Fatalf("newHandler: %v", err)
	}
	api := httptest.NewServer(handler)
	t.Cleanup(api.Close)
	return api, fake
}

type response struct {
	status int
	header http.Header
	body   string
}

func do(t *testing.T, method, url, body string) response {
	t.Helper()
	var r io.Reader
	if body != "" {
		r = strings.NewReader(body)
	}
	req, err := http.NewRequest(method, url, r)
	if err != nil {
		t.Fatal(err)
	}
	if body != "" {
		req.Header.Set("Content-Type", "application/json")
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	b, _ := io.ReadAll(resp.Body)
	return response{status: resp.StatusCode, header: resp.Header, body: string(b)}
}

func expect(t *testing.T, got response, status int, body string) {
	t.Helper()
	if got.status != status {
		t.Errorf("status = %d, want %d (body %q)", got.status, status, got.body)
	}
	if body != "" && got.body != body {
		t.Errorf("body = %q, want %q", got.body, body)
	}
}

func TestHealthz(t *testing.T) {
	api, _ := newTestAPI(t)
	expect(t, do(t, http.MethodGet, api.URL+"/healthz", ""), http.StatusOK, "ok")
}

// TestCORS: with no ALLOWED_ORIGINS no CORS header is ever sent, so browsers
// keep other sites out; listed origins get their own origin echoed back.
func TestCORS(t *testing.T) {
	cors := []string{"Access-Control-Allow-Origin", "Access-Control-Allow-Headers", "Access-Control-Allow-Methods"}
	preflight := func(url, origin string) response {
		t.Helper()
		req, _ := http.NewRequest(http.MethodOptions, url, nil)
		req.Header.Set("Origin", origin)
		req.Header.Set("Access-Control-Request-Method", "POST")
		resp, err := http.DefaultClient.Do(req)
		if err != nil {
			t.Fatal(err)
		}
		defer resp.Body.Close()
		b, _ := io.ReadAll(resp.Body)
		return response{status: resp.StatusCode, header: resp.Header, body: string(b)}
	}

	api, _ := newTestAPI(t)
	for _, path := range []string{"/healthz", "/events", "/metrics/features"} {
		got := preflight(api.URL+path, "https://evil.example.com")
		for _, h := range cors {
			if v := got.header.Get(h); v != "" {
				t.Errorf("default config, OPTIONS %s: %s = %q, want none", path, h, v)
			}
		}
	}
	expect(t, preflight(api.URL+"/events", "https://evil.example.com"), http.StatusMethodNotAllowed, "")

	api, _ = newTestAPIWith(t, func(c *config.Config) { c.AllowedOrigins = []string{"https://dash.example.com"} })
	got := preflight(api.URL+"/events", "https://dash.example.com")
	expect(t, got, http.StatusNoContent, "")
	if got.header.Get("Access-Control-Allow-Origin") != "https://dash.example.com" || !strings.Contains(got.header.Get("Access-Control-Allow-Headers"), "Content-Type") {
		t.Errorf("allowed preflight headers = %v", got.header)
	}
	if got := preflight(api.URL+"/events", "https://evil.example.com"); got.header.Get("Access-Control-Allow-Origin") != "" || got.status != http.StatusMethodNotAllowed {
		t.Errorf("unlisted origin got %d with Allow-Origin %q", got.status, got.header.Get("Access-Control-Allow-Origin"))
	}

	req, _ := http.NewRequest(http.MethodGet, api.URL+"/metrics/features", nil)
	req.Header.Set("Origin", "https://dash.example.com")
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	resp.Body.Close()
	if resp.StatusCode != http.StatusOK || resp.Header.Get("Access-Control-Allow-Origin") != "https://dash.example.com" || resp.Header.Get("Vary") != "Origin" {
		t.Errorf("simple request: %d, headers %v", resp.StatusCode, resp.Header)
	}
}

func TestEventBodyLimit(t *testing.T) {
	api, fake := newTestAPI(t)
	pad := strings.Repeat("x", 64<<10)
	got := do(t, http.MethodPost, api.URL+"/events", `{"featureName":"f","custom":{"pad":"`+pad+`"}}`)
	expect(t, got, http.StatusRequestEntityTooLarge, `{"error":"request body larger than 65536 bytes"}`+"\n")
	if docs := fake.Docs("default/f"); len(docs) != 0 {
		t.Errorf("oversized event was stored")
	}
	// Just under the cap is fine.
	small := strings.Repeat("x", 60<<10)
	expect(t, do(t, http.MethodPost, api.URL+"/events", `{"featureName":"f","custom":{"pad":"`+small+`"}}`), http.StatusCreated, "")
}

func TestServerTimeouts(t *testing.T) {
	srv := newServer(":0", http.NotFoundHandler())
	if srv.ReadHeaderTimeout == 0 || srv.ReadTimeout == 0 || srv.WriteTimeout == 0 || srv.IdleTimeout == 0 {
		t.Errorf("a timeout is unset: %+v", srv)
	}
	if srv.WriteTimeout <= 15*time.Second {
		t.Errorf("WriteTimeout %v leaves no room for the 15s summary query", srv.WriteTimeout)
	}
}

func TestFeatures(t *testing.T) {
	api, _ := newTestAPI(t)
	got := do(t, http.MethodGet, api.URL+"/metrics/features", "")
	expect(t, got, http.StatusOK, `{"features":["ai-code-review"]}`+"\n")
	if ct := got.header.Get("Content-Type"); ct != "application/json" {
		t.Errorf("Content-Type = %q", ct)
	}
}

func TestPages(t *testing.T) {
	api, _ := newTestAPI(t)
	for path, marker := range map[string]string{
		"/":                    "<html",
		"/dashboard":           "chart",
		"/dashboard?feature=x": "chart",
	} {
		got := do(t, http.MethodGet, api.URL+path, "")
		expect(t, got, http.StatusOK, "")
		if ct := got.header.Get("Content-Type"); ct != "text/html; charset=utf-8" {
			t.Errorf("GET %s: Content-Type = %q", path, ct)
		}
		if !strings.Contains(strings.ToLower(got.body), marker) {
			t.Errorf("GET %s: body lacks %q", path, marker)
		}
	}
	js := do(t, http.MethodGet, api.URL+"/static/chart.umd.min.js", "")
	expect(t, js, http.StatusOK, "")
	if ct := js.header.Get("Content-Type"); !strings.HasPrefix(ct, "text/javascript") {
		t.Errorf("chart.js Content-Type = %q", ct)
	}
	if !strings.HasPrefix(js.body, "/*!\n * Chart.js v4.5.0") || js.header.Get("Cache-Control") == "" {
		t.Errorf("chart.js served wrongly: %q..., Cache-Control %q", js.body[:min(40, len(js.body))], js.header.Get("Cache-Control"))
	}
	expect(t, do(t, http.MethodPost, api.URL+"/static/chart.umd.min.js", "{}"), http.StatusMethodNotAllowed, "")

	for _, path := range []string{"/no-such-page", "/dashboard/below", "/index.html", "/static/nope.js", "/static/../main.go", "/static/"} {
		expect(t, do(t, http.MethodGet, api.URL+path, ""), http.StatusNotFound, "404 page not found\n")
	}
}

func TestPostEventStoresEnvelope(t *testing.T) {
	api, fake := newTestAPI(t)
	before := time.Now().UTC().Truncate(time.Second)
	got := do(t, http.MethodPost, api.URL+"/events", `{
		"featureName": "ai-code-review",
		"featureVersion": "2.1.0",
		"source": "ado-pipeline",
		"timestamp": "2026-01-02T03:04:05Z",
		"receivedAt": "client value is ignored",
		"id": "client id is ignored",
		"unknownTopLevel": "dropped",
		"custom": {"repository": "repo-a", "prId": 42, "nested": {"a": [1, "two", true, null]}}
	}`)
	expect(t, got, http.StatusCreated, "")
	if ct := got.header.Get("Content-Type"); ct != "application/json" {
		t.Errorf("Content-Type = %q", ct)
	}
	var created map[string]string
	if err := json.Unmarshal([]byte(got.body), &created); err != nil {
		t.Fatalf("response body %q: %v", got.body, err)
	}
	if !regexp.MustCompile(`^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$`).MatchString(created["eventId"]) || len(created) != 1 {
		t.Fatalf("response = %v, want only a v4 UUID eventId", created)
	}

	docs := fake.Docs("default/" + feature)
	if len(docs) != 1 {
		t.Fatalf("stored %d documents, want 1", len(docs))
	}
	doc := docs[0]
	receivedAt, err := time.Parse(time.RFC3339, fmt.Sprint(doc["receivedAt"]))
	if err != nil || receivedAt.Before(before) || receivedAt.After(time.Now().UTC().Add(time.Second)) {
		t.Errorf("receivedAt = %v, want server time in RFC3339", doc["receivedAt"])
	}
	delete(doc, "receivedAt")
	want := map[string]any{
		"id":             created["eventId"],
		"eventId":        created["eventId"],
		"timestamp":      "2026-01-02T03:04:05Z",
		"featureName":    "ai-code-review",
		"tenantId":       "default",
		"featureVersion": "2.1.0",
		"source":         "ado-pipeline",
		"schemaVersion":  "1",
		"custom": map[string]any{
			"repository": "repo-a",
			"prId":       float64(42),
			"nested":     map[string]any{"a": []any{float64(1), "two", true, nil}},
		},
	}
	assertJSONEqual(t, doc, want)
}

func TestPostEventDefaults(t *testing.T) {
	api, fake := newTestAPI(t)
	got := do(t, http.MethodPost, api.URL+"/events", `{"featureName":"other-feature","eventId":"evt-1","schemaVersion":"7"}`)
	expect(t, got, http.StatusCreated, `{"eventId":"evt-1"}`+"\n")

	docs := fake.Docs("default/other-feature")
	if len(docs) != 1 {
		t.Fatalf("stored %d documents, want 1", len(docs))
	}
	doc := docs[0]
	if doc["id"] != "evt-1" || doc["schemaVersion"] != "7" {
		t.Errorf("doc = %v", doc)
	}
	if _, err := time.Parse(time.RFC3339, fmt.Sprint(doc["timestamp"])); err != nil {
		t.Errorf("timestamp = %v, want server time", doc["timestamp"])
	}
	for _, omitted := range []string{"featureVersion", "source", "custom"} {
		if _, ok := doc[omitted]; ok {
			t.Errorf("%s stored although empty", omitted)
		}
	}
}

func TestPostEventErrors(t *testing.T) {
	api, fake := newTestAPI(t)

	expect(t, do(t, http.MethodGet, api.URL+"/events", ""), http.StatusMethodNotAllowed, `{"error":"method not allowed"}`+"\n")
	expect(t, do(t, http.MethodPut, api.URL+"/events", `{}`), http.StatusMethodNotAllowed, `{"error":"method not allowed"}`+"\n")
	expect(t, do(t, http.MethodPost, api.URL+"/events", `{}`), http.StatusBadRequest, `{"error":"featureName is required"}`+"\n")
	expect(t, do(t, http.MethodPost, api.URL+"/events", `{"featureName":""}`), http.StatusBadRequest, `{"error":"featureName is required"}`+"\n")

	bad := do(t, http.MethodPost, api.URL+"/events", `{"featureName":`)
	expect(t, bad, http.StatusBadRequest, `{"error":"invalid JSON: unexpected EOF"}`+"\n")
	if ct := bad.header.Get("Content-Type"); ct != "text/plain; charset=utf-8" {
		t.Errorf("error Content-Type = %q", ct)
	}
	expect(t, do(t, http.MethodPost, api.URL+"/events", `{"featureName":1}`), http.StatusBadRequest, "")

	expect(t, do(t, http.MethodPost, api.URL+"/events", `{"featureName":"f","eventId":"dup"}`), http.StatusCreated, "")
	expect(t, do(t, http.MethodPost, api.URL+"/events", `{"featureName":"f","eventId":"dup"}`), http.StatusConflict, `{"error":"duplicate eventId"}`+"\n")

	fake.FailWith(http.StatusServiceUnavailable)
	expect(t, do(t, http.MethodPost, api.URL+"/events", `{"featureName":"f"}`), http.StatusBadGateway, `{"error":"failed to store event"}`+"\n")
}

func TestSummaryErrors(t *testing.T) {
	api, fake := newTestAPI(t)
	expect(t, do(t, http.MethodGet, api.URL+"/metrics/summary", ""), http.StatusBadRequest, `{"error":"feature query param is required"}`+"\n")
	expect(t, do(t, http.MethodGet, api.URL+"/metrics/summary?feature=not-listed", ""), http.StatusNotFound, `{"error":"unknown feature"}`+"\n")
	if n := len(fake.Queries()); n != 0 {
		t.Errorf("rejected requests still ran %d queries", n)
	}
	fake.FailWith(http.StatusInternalServerError)
	expect(t, do(t, http.MethodGet, api.URL+"/metrics/summary?feature="+feature, ""), http.StatusBadGateway, `{"error":"failed to query metrics"}`+"\n")
}

func TestSummaryQuery(t *testing.T) {
	api, fake := newTestAPI(t)
	for days, want := range map[string]int{"": 30, "7": 7, "0": 30, "-3": 30, "abc": 30, "400": 400} {
		before := time.Now().UTC()
		got := do(t, http.MethodGet, api.URL+"/metrics/summary?feature="+feature+"&days="+days, "")
		expect(t, got, http.StatusOK, "")
		var s map[string]any
		if err := json.Unmarshal([]byte(got.body), &s); err != nil {
			t.Fatal(err)
		}
		if s["windowDays"] != float64(want) {
			t.Errorf("days=%q: windowDays = %v, want %d", days, s["windowDays"], want)
		}
		queries := fake.Queries()
		q := queries[len(queries)-1]
		if q.Text != "SELECT c.custom, c.timestamp FROM c WHERE c.tenantId = @tenant AND c.featureName = @feature AND c.timestamp >= @since ORDER BY c.timestamp ASC" {
			t.Errorf("query text = %q", q.Text)
		}
		if q.PartitionKey != "default/"+feature || q.Parameters["@feature"] != feature || q.Parameters["@tenant"] != "default" {
			t.Errorf("query partition/tenant/feature = %q/%v/%v", q.PartitionKey, q.Parameters["@tenant"], q.Parameters["@feature"])
		}
		since, err := time.Parse(time.RFC3339, fmt.Sprint(q.Parameters["@since"]))
		wantSince := before.AddDate(0, 0, -want).Truncate(time.Second)
		if err != nil || since.Before(wantSince.Add(-time.Second)) || since.After(wantSince.Add(2*time.Second)) {
			t.Errorf("days=%q: @since = %v, want about %v", days, q.Parameters["@since"], wantSince)
		}
	}
}

func TestSummaryEmpty(t *testing.T) {
	api, _ := newTestAPI(t)
	got := do(t, http.MethodGet, api.URL+"/metrics/summary?feature="+feature+"&days=2", "")
	expect(t, got, http.StatusOK, "")
	if ct := got.header.Get("Content-Type"); ct != "application/json" {
		t.Errorf("Content-Type = %q", ct)
	}
	var s map[string]any
	if err := json.Unmarshal([]byte(got.body), &s); err != nil {
		t.Fatal(err)
	}
	// Nil slices marshal as null, and the day ranges still cover the window.
	for _, k := range []string{"byRepository", "topFiles", "byErrorType", "byModel", "byEngineVersion"} {
		if s[k] != nil {
			t.Errorf("%s = %v, want null", k, s[k])
		}
	}
	if days := s["byDay"].([]any); len(days) != 3 {
		t.Errorf("byDay has %d entries, want 3 (window of 2 days plus today)", len(days))
	}
}

// TestSummaryGolden feeds a mixed set of events through the summary and
// compares the whole response with testdata/summary.golden.json. Dates are
// written relative to today ("D-3") so the file does not age.
func TestSummaryGolden(t *testing.T) {
	api, fake := newTestAPI(t)
	today := time.Now().UTC().Truncate(24 * time.Hour)
	at := func(daysAgo int, hour int) string {
		return today.AddDate(0, 0, -daysAgo).Add(time.Duration(hour) * time.Hour).Format(time.RFC3339)
	}
	n := 0
	putTenant := func(tenant, featureName, ts string, custom map[string]any) {
		n++
		fake.Put(t, map[string]any{"id": fmt.Sprintf("e%02d", n), "tenantId": tenant, "featureName": featureName, "timestamp": ts, "custom": custom})
	}
	put := func(featureName, ts string, custom map[string]any) { putTenant("default", featureName, ts, custom) }

	// Outside the 30-day window, another feature, another tenant: all ignored.
	put(feature, at(45, 1), map[string]any{"repository": "repo-a", "prId": "old", "commentsCount": 9})
	put("other-feature", at(2, 1), map[string]any{"repository": "repo-a", "prId": "x", "commentsCount": 9})
	putTenant("acme", feature, at(2, 1), map[string]any{"repository": "repo-a", "prId": "y", "commentsCount": 9})

	put(feature, at(5, 1), map[string]any{
		"repository": "repo-a", "prId": "1", "outcome": "success", "model": "gpt-5-mini", "engineVersion": "1.2.0",
		"commentsCount": 3, "commentsProposed": 5, "commentsSkippedDuplicate": 2,
		"promptTokens": 120000, "completionTokens": 30000, "reasoningTokens": 10000, "cachedTokens": 50000, "tokensUsed": 150000,
		"latencyMs":         1000,
		"severityBreakdown": map[string]any{"critical": 1, "warning": "2", "suggestion": 0},
		"filesWithComments": []any{"/src/a.go", "/src/shared.go", ""},
	})
	// Same PR again: comments and tokens count, the PR does not.
	put(feature, at(3, 2), map[string]any{
		"repository": "repo-a", "prId": "1", "outcome": "success", "model": "gpt-5.4-mini", "engineVersion": "1.2.0",
		"commentsCount": 0, "commentsProposed": 1,
		"promptTokens": 80000, "completionTokens": 10000, "tokensUsed": 90000,
		"latencyMs":         3000,
		"filesWithComments": "/src/a.go",
	})
	// Errors: tokens and latency still count; nothing else does.
	put(feature, at(3, 3), map[string]any{
		"repository": "repo-a", "prId": "2", "outcome": "error", "errorType": "timeout", "model": "unpriced-model",
		"commentsCount": 4, "promptTokens": 5000, "tokensUsed": 5000, "latencyMs": 60000,
	})
	put(feature, at(3, 4), map[string]any{"repository": "repo-b", "outcome": "error", "model": "gpt-5-mini", "engineVersion": "1.3.0"})
	put(feature, at(2, 5), map[string]any{"repository": "repo-b", "outcome": "error", "errorType": "timeout", "engineVersion": "1.3.0"})
	// Partial run, numbers sent as strings, a numeric prId.
	put(feature, at(2, 6), map[string]any{
		"repository": "repo-b", "prId": 7, "outcome": "partial", "model": "gpt-5.6-luna", "engineVersion": "1.3.0",
		"commentsCount": "2", "promptTokens": "200000", "completionTokens": "50000", "tokensUsed": "250000", "latencyMs": "2000",
		"severityBreakdown": map[string]any{"unknown": 2},
		"filesWithComments": []any{"/src/shared.go", "/src/b.go"},
	})
	// A review with no PR id: counted as a review, not as a PR.
	put(feature, at(1, 7), map[string]any{"repository": "repo-b", "outcome": "success", "commentsCount": 1, "latencyMs": 0})
	// Unparsable timestamp: kept by the query, but has no day bucket.
	put(feature, "not-a-timestamp", map[string]any{"repository": "repo-c", "prId": "9", "commentsCount": 1, "latencyMs": 500, "promptTokens": 1000000, "model": "gpt-5-mini"})
	// Twelve commented files in one run, so the top-10 cut applies.
	files := []any{}
	for i := range 12 {
		files = append(files, fmt.Sprintf("/many/%02d.go", i))
	}
	put(feature, at(0, 0), map[string]any{"repository": "repo-c", "prId": "10", "outcome": "success", "commentsCount": 12, "filesWithComments": files})

	got := do(t, http.MethodGet, api.URL+"/metrics/summary?feature="+feature, "")
	expect(t, got, http.StatusOK, "")
	actual := normaliseSummary(t, got.body, today)

	golden := filepath.Join("testdata", "summary.golden.json")
	if *update {
		if err := os.MkdirAll("testdata", 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(golden, actual, 0o644); err != nil {
			t.Fatal(err)
		}
	}
	want, err := os.ReadFile(golden)
	if err != nil {
		t.Fatalf("read golden file (run with -update to create it): %v", err)
	}
	if !bytes.Equal(actual, want) {
		t.Errorf("summary differs from %s; rerun with -update if the change is intended.\n--- got ---\n%s", golden, actual)
	}
}

// normaliseSummary makes the summary comparable across runs: dates become
// offsets from today, and lists whose order the API does not define (map
// iteration, or ties in an unstable sort) are put in a fixed order.
func normaliseSummary(t *testing.T, body string, today time.Time) []byte {
	t.Helper()
	dates := regexp.MustCompile(`"(\d{4}-\d{2}-\d{2})"`)
	body = dates.ReplaceAllStringFunc(body, func(m string) string {
		d, err := time.Parse("2006-01-02", strings.Trim(m, `"`))
		if err != nil {
			return m
		}
		return fmt.Sprintf(`"D-%d"`, int(today.Sub(d).Hours()/24))
	})
	var s map[string]any
	if err := json.Unmarshal([]byte(body), &s); err != nil {
		t.Fatal(err)
	}
	sortBy := func(key string, less func(a, b map[string]any) bool) {
		list, _ := s[key].([]any)
		sort.SliceStable(list, func(i, j int) bool { return less(list[i].(map[string]any), list[j].(map[string]any)) })
	}
	str := func(m map[string]any, k string) string { return fmt.Sprint(m[k]) }
	num := func(m map[string]any, k string) float64 { f, _ := m[k].(float64); return f }
	sortBy("byRepository", func(a, b map[string]any) bool { return str(a, "repository") < str(b, "repository") })
	sortBy("byModel", func(a, b map[string]any) bool {
		if num(a, "runs") != num(b, "runs") {
			return num(a, "runs") > num(b, "runs")
		}
		return str(a, "model") < str(b, "model")
	})
	sortBy("byErrorType", func(a, b map[string]any) bool {
		if num(a, "count") != num(b, "count") {
			return num(a, "count") > num(b, "count")
		}
		return str(a, "errorType") < str(b, "errorType")
	})
	out, err := json.MarshalIndent(s, "", "  ")
	if err != nil {
		t.Fatal(err)
	}
	return append(out, '\n')
}

func assertJSONEqual(t *testing.T, got, want any) {
	t.Helper()
	g, _ := json.Marshal(got)
	w, _ := json.Marshal(want)
	if !bytes.Equal(g, w) {
		t.Errorf("got  %s\nwant %s", g, w)
	}
}

// Guard against the summary keys drifting without the golden file noticing,
// e.g. a field renamed and the golden regenerated in the same change.
func TestSummaryKeys(t *testing.T) {
	api, _ := newTestAPI(t)
	got := do(t, http.MethodGet, api.URL+"/metrics/summary?feature="+feature, "")
	var s map[string]any
	if err := json.Unmarshal([]byte(got.body), &s); err != nil {
		t.Fatal(err)
	}
	keys := make([]string, 0, len(s))
	for k := range s {
		keys = append(keys, k)
	}
	slices.Sort(keys)
	want := []string{
		"avgLatencyMs", "byDay", "byDayCost", "byDayLatency", "byEngineVersion", "byErrorType", "byModel",
		"byRepository", "dedupRate", "errorRate", "featureName", "p95LatencyMs", "severityBreakdown", "topFiles",
		"totalErrors", "totalEstCostUsd", "totalEvents", "totalPRsReviewed", "totalPartial",
		"totalReviewsWithComments", "totalReviewsWithoutComments", "totalTokens", "windowDays",
	}
	if !slices.Equal(keys, want) {
		t.Errorf("summary keys = %v\nwant %v", keys, want)
	}
}

func TestTenants(t *testing.T) {
	api, fake := newTestAPI(t)

	expect(t, do(t, http.MethodPost, api.URL+"/events", `{"featureName":"ai-code-review","tenantId":"acme","eventId":"a1","custom":{"prId":"1","repository":"r"}}`), http.StatusCreated, `{"eventId":"a1"}`+"\n")
	// Ids are unique per partition, so another tenant may reuse one.
	expect(t, do(t, http.MethodPost, api.URL+"/events", `{"featureName":"ai-code-review","eventId":"a1","custom":{"prId":"2","repository":"r"}}`), http.StatusCreated, "")
	expect(t, do(t, http.MethodPost, api.URL+"/events", `{"featureName":"ai-code-review","tenantId":"acme","eventId":"a1"}`), http.StatusConflict, "")

	if docs := fake.Docs("acme/" + feature); len(docs) != 1 || docs[0]["tenantId"] != "acme" {
		t.Errorf("acme partition = %v", docs)
	}
	if docs := fake.Docs("default/" + feature); len(docs) != 1 || docs[0]["tenantId"] != "default" {
		t.Errorf("default partition = %v", docs)
	}

	for _, bad := range []string{"-lead", "has space", "slash/inside", "ünïcode", strings.Repeat("a", 65)} {
		body, _ := json.Marshal(map[string]string{"featureName": feature, "tenantId": bad})
		expect(t, do(t, http.MethodPost, api.URL+"/events", string(body)), http.StatusBadRequest, `{"error":"invalid tenantId"}`+"\n")
	}
	expect(t, do(t, http.MethodGet, api.URL+"/metrics/summary?feature="+feature+"&tenantId=a%2Fb", ""), http.StatusBadRequest, `{"error":"invalid tenantId"}`+"\n")

	for tenant, wantPR := range map[string]float64{"": 1, "default": 1, "acme": 1, "nobody": 0} {
		got := do(t, http.MethodGet, api.URL+"/metrics/summary?feature="+feature+"&tenantId="+tenant, "")
		expect(t, got, http.StatusOK, "")
		var s map[string]any
		if err := json.Unmarshal([]byte(got.body), &s); err != nil {
			t.Fatal(err)
		}
		if s["totalPRsReviewed"] != wantPR {
			t.Errorf("tenant %q: totalPRsReviewed = %v, want %v", tenant, s["totalPRsReviewed"], wantPR)
		}
		q := fake.Queries()[len(fake.Queries())-1]
		wantTenant := tenant
		if wantTenant == "" {
			wantTenant = "default"
		}
		if q.PartitionKey != wantTenant+"/"+feature || q.Parameters["@tenant"] != wantTenant {
			t.Errorf("tenant %q: query partition %q, @tenant %v", tenant, q.PartitionKey, q.Parameters["@tenant"])
		}
	}
}

// TestEventsAuth: auth guards POST /events and nothing else, and a service
// with no auth configured refuses writes instead of accepting them.
func TestEventsAuth(t *testing.T) {
	key := strings.Repeat("s", auth.MinKeyLength)
	api, _ := newTestAPIWith(t, func(c *config.Config) {
		c.Auth = auth.Config{Mode: auth.Mode{Key: true}, APIKey: key}
	})
	post := func(apiKey string) response {
		t.Helper()
		req, _ := http.NewRequest(http.MethodPost, api.URL+"/events", strings.NewReader(`{"featureName":"`+feature+`"}`))
		req.Header.Set("Content-Type", "application/json")
		if apiKey != "" {
			req.Header.Set("X-Api-Key", apiKey)
		}
		resp, err := http.DefaultClient.Do(req)
		if err != nil {
			t.Fatal(err)
		}
		defer resp.Body.Close()
		b, _ := io.ReadAll(resp.Body)
		return response{status: resp.StatusCode, header: resp.Header, body: string(b)}
	}
	expect(t, post(""), http.StatusUnauthorized, "{\"error\":\"credentials required: send an API key (X-Api-Key)\"}\n")
	expect(t, post(strings.Repeat("x", auth.MinKeyLength)), http.StatusUnauthorized, "{\"error\":\"invalid credentials\"}\n")
	expect(t, post(key), http.StatusCreated, "")

	// Reads, pages and the probe stay open (the dashboard is protected by
	// Container Apps sign-in, not by this service).
	expect(t, do(t, http.MethodGet, api.URL+"/healthz", ""), http.StatusOK, "ok")
	expect(t, do(t, http.MethodGet, api.URL+"/metrics/features", ""), http.StatusOK, "")
	expect(t, do(t, http.MethodGet, api.URL+"/metrics/summary?feature="+feature, ""), http.StatusOK, "")

	closed, _ := newTestAPIWith(t, func(c *config.Config) { c.Auth = auth.Config{} })
	expect(t, do(t, http.MethodPost, closed.URL+"/events", `{"featureName":"`+feature+`"}`), http.StatusServiceUnavailable, "")
}
