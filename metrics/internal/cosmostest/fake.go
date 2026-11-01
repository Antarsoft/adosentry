// Package cosmostest is an in-memory stand-in for the slice of the Cosmos DB
// REST API that the metrics service uses: create a document, and run the
// single-partition summary query. Tests point the real azcosmos client at it,
// so the SDK's request building and response parsing stay under test.
//
// It is test infrastructure only; nothing outside _test.go files imports it.
package cosmostest

import (
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"sort"
	"strings"
	"sync"
	"testing"
)

// Server is a fake Cosmos DB account holding one container.
type Server struct {
	URL string
	// Client trusts the fake's certificate when it was started with NewTLS.
	Client *http.Client

	mu      sync.Mutex
	docs    map[string]map[string]json.RawMessage // partition key -> id -> document; key levels joined by "/"
	queries []Query
	fail    int // when non-zero, every data request answers with this status
	auth    []string
}

// Query records one query request as the fake received it.
type Query struct {
	Text         string
	PartitionKey string // levels joined by "/", e.g. "default/ai-code-review"
	Parameters   map[string]any
}

// New starts a fake account over plain HTTP and stops it when the test
// ends. That suits key auth; token auth needs NewTLS.
func New(t testing.TB) *Server {
	t.Helper()
	s := &Server{docs: map[string]map[string]json.RawMessage{}}
	ts := httptest.NewServer(http.HandlerFunc(s.serve))
	t.Cleanup(ts.Close)
	s.URL, s.Client = ts.URL, ts.Client()
	return s
}

// NewTLS starts a fake account over HTTPS. The Azure SDK only sends bearer
// tokens over TLS, so Entra ID tests need this; use Client as transport.
func NewTLS(t testing.TB) *Server {
	t.Helper()
	s := &Server{docs: map[string]map[string]json.RawMessage{}}
	ts := httptest.NewTLSServer(http.HandlerFunc(s.serve))
	t.Cleanup(ts.Close)
	s.URL, s.Client = ts.URL, ts.Client()
	return s
}

// AuthHeaders returns the Authorization header of every request so far.
func (s *Server) AuthHeaders() []string {
	s.mu.Lock()
	defer s.mu.Unlock()
	return append([]string(nil), s.auth...)
}

// FailWith makes every following create or query answer with status.
// Pass 0 to stop failing.
func (s *Server) FailWith(status int) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.fail = status
}

// Put stores a document directly, as if a sender had posted it earlier.
func (s *Server) Put(t testing.TB, doc map[string]any) {
	t.Helper()
	b, err := json.Marshal(doc)
	if err != nil {
		t.Fatalf("marshal seed document: %v", err)
	}
	tenant, _ := doc["tenantId"].(string)
	feature, _ := doc["featureName"].(string)
	pk := tenant + "/" + feature
	id, _ := doc["id"].(string)
	s.mu.Lock()
	defer s.mu.Unlock()
	s.put(pk, id, b)
}

// Docs returns every stored document in one partition ("tenant/feature"),
// ordered by id.
func (s *Server) Docs(partitionKey string) []map[string]any {
	s.mu.Lock()
	defer s.mu.Unlock()
	ids := make([]string, 0, len(s.docs[partitionKey]))
	for id := range s.docs[partitionKey] {
		ids = append(ids, id)
	}
	sort.Strings(ids)
	out := make([]map[string]any, 0, len(ids))
	for _, id := range ids {
		var m map[string]any
		_ = json.Unmarshal(s.docs[partitionKey][id], &m)
		out = append(out, m)
	}
	return out
}

// Queries returns the queries received so far.
func (s *Server) Queries() []Query {
	s.mu.Lock()
	defer s.mu.Unlock()
	return append([]Query(nil), s.queries...)
}

func (s *Server) put(pk, id string, doc json.RawMessage) bool {
	if s.docs[pk] == nil {
		s.docs[pk] = map[string]json.RawMessage{}
	}
	if _, exists := s.docs[pk][id]; exists {
		return false
	}
	s.docs[pk][id] = doc
	return true
}

func (s *Server) serve(w http.ResponseWriter, r *http.Request) {
	s.mu.Lock()
	s.auth = append(s.auth, r.Header.Get("Authorization"))
	s.mu.Unlock()
	w.Header().Set("Content-Type", "application/json")
	// The SDK reads account properties first; an empty object is enough.
	if r.Method == http.MethodGet && r.URL.Path == "/" {
		_, _ = w.Write([]byte(`{}`))
		return
	}
	if r.Method != http.MethodPost || !strings.HasSuffix(r.URL.Path, "/docs") {
		http.Error(w, `{"code":"NotFound"}`, http.StatusNotFound)
		return
	}

	s.mu.Lock()
	defer s.mu.Unlock()
	if s.fail != 0 {
		w.WriteHeader(s.fail)
		_, _ = w.Write([]byte(`{"code":"InjectedFailure","message":"cosmostest: injected failure"}`))
		return
	}

	pk := partitionKey(r.Header.Get("x-ms-documentdb-partitionkey"))
	body, _ := io.ReadAll(r.Body)
	if strings.EqualFold(r.Header.Get("x-ms-documentdb-query"), "true") {
		s.query(w, pk, body)
		return
	}

	var doc struct {
		ID string `json:"id"`
	}
	if err := json.Unmarshal(body, &doc); err != nil || doc.ID == "" {
		http.Error(w, `{"code":"BadRequest"}`, http.StatusBadRequest)
		return
	}
	if !s.put(pk, doc.ID, body) {
		w.WriteHeader(http.StatusConflict)
		_, _ = w.Write([]byte(`{"code":"Conflict","message":"Entity with the specified id already exists in the system."}`))
		return
	}
	w.WriteHeader(http.StatusCreated)
}

// query evaluates the one query shape the service sends:
//
//	SELECT c.custom, c.timestamp FROM c
//	WHERE c.tenantId = @tenant AND c.featureName = @feature AND c.timestamp >= @since
//	ORDER BY c.timestamp ASC
//
// Any other query text is still recorded, then answered with no rows.
func (s *Server) query(w http.ResponseWriter, pk string, body []byte) {
	var req struct {
		Query      string `json:"query"`
		Parameters []struct {
			Name  string `json:"name"`
			Value any    `json:"value"`
		} `json:"parameters"`
	}
	_ = json.Unmarshal(body, &req)
	q := Query{Text: req.Query, PartitionKey: pk, Parameters: map[string]any{}}
	for _, p := range req.Parameters {
		q.Parameters[p.Name] = p.Value
	}
	s.queries = append(s.queries, q)

	type row struct {
		Custom    json.RawMessage `json:"custom,omitempty"`
		Timestamp string          `json:"timestamp"`
		id        string
	}
	rows := []row{}
	if strings.Contains(req.Query, "c.tenantId = @tenant AND c.featureName = @feature") {
		tenant, _ := q.Parameters["@tenant"].(string)
		feature, _ := q.Parameters["@feature"].(string)
		since, _ := q.Parameters["@since"].(string)
		for _, raw := range s.docs[pk] {
			var d struct {
				ID          string          `json:"id"`
				TenantID    string          `json:"tenantId"`
				FeatureName string          `json:"featureName"`
				Timestamp   string          `json:"timestamp"`
				Custom      json.RawMessage `json:"custom"`
			}
			if json.Unmarshal(raw, &d) != nil || d.TenantID != tenant || d.FeatureName != feature || d.Timestamp < since {
				continue
			}
			rows = append(rows, row{Custom: d.Custom, Timestamp: d.Timestamp, id: d.ID})
		}
		// Ties broken by id so results never depend on map order.
		sort.Slice(rows, func(i, j int) bool {
			if rows[i].Timestamp != rows[j].Timestamp {
				return rows[i].Timestamp < rows[j].Timestamp
			}
			return rows[i].id < rows[j].id
		})
	}
	_ = json.NewEncoder(w).Encode(map[string]any{"Documents": rows, "_count": len(rows)})
}

// partitionKey turns the header value `["a","b"]` back into `a/b`.
func partitionKey(header string) string {
	var parts []string
	if json.Unmarshal([]byte(header), &parts) != nil {
		return ""
	}
	return strings.Join(parts, "/")
}
