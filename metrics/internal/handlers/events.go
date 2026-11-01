package handlers

import (
	"context"
	"crypto/rand"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"net/http"
	"regexp"
	"time"

	"github.com/antarsoft/pullpicket/metrics/internal/storage"
)

const (
	// storeTimeout bounds one Cosmos write.
	storeTimeout = 10 * time.Second
	// MaxEventBytes caps a POST /events body. A review event is a few KB;
	// anything near the cap is a misbehaving sender.
	MaxEventBytes = 64 << 10
)

// Event is the envelope every sender uses. Only FeatureName is required.
// Everything feature-specific (repository, prId, commentsCount, tokens, and
// whatever a future feature needs) goes in Custom, which is deliberately
// untyped so it can change without a schema migration.
type Event struct {
	ID             string         `json:"id"` // Cosmos document id, always equal to EventID
	EventID        string         `json:"eventId"`
	Timestamp      string         `json:"timestamp"`   // event time (RFC3339); the server fills it in if omitted
	ReceivedAt     string         `json:"receivedAt"`  // server receipt time, always set by the server
	FeatureName    string         `json:"featureName"` // required; partition key (second level); e.g. "ai-code-review"
	TenantID       string         `json:"tenantId"`    // optional; partition key (first level); "default" when omitted
	FeatureVersion string         `json:"featureVersion,omitempty"`
	Source         string         `json:"source,omitempty"` // e.g. "ado-pipeline", "github-action", "manual"
	SchemaVersion  string         `json:"schemaVersion,omitempty"`
	Custom         map[string]any `json:"custom,omitempty"` // free-form, feature-specific payload
}

// handleEvents accepts any JSON object with a non-empty featureName. Every
// envelope field, and anything under custom, is stored as sent: there is no
// schema to validate against, on purpose. Unknown top-level fields are
// dropped.
func (a *API) handleEvents(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, `{"error":"method not allowed"}`, http.StatusMethodNotAllowed)
		return
	}
	var e Event
	r.Body = http.MaxBytesReader(w, r.Body, MaxEventBytes)
	if err := json.NewDecoder(r.Body).Decode(&e); err != nil {
		var tooLarge *http.MaxBytesError
		if errors.As(err, &tooLarge) {
			http.Error(w, fmt.Sprintf(`{"error":"request body larger than %d bytes"}`, MaxEventBytes), http.StatusRequestEntityTooLarge)
			return
		}
		http.Error(w, fmt.Sprintf(`{"error":"invalid JSON: %s"}`, err), http.StatusBadRequest)
		return
	}
	if e.FeatureName == "" {
		http.Error(w, `{"error":"featureName is required"}`, http.StatusBadRequest)
		return
	}
	if e.TenantID == "" {
		e.TenantID = storage.DefaultTenant
	}
	if !validTenantID(e.TenantID) {
		http.Error(w, `{"error":"invalid tenantId"}`, http.StatusBadRequest)
		return
	}
	now := a.now().UTC().Format(time.RFC3339)
	if e.EventID == "" {
		e.EventID = newID()
	}
	e.ID = e.EventID
	if e.Timestamp == "" {
		e.Timestamp = now
	}
	e.ReceivedAt = now
	if e.SchemaVersion == "" {
		e.SchemaVersion = "1"
	}

	doc, err := json.Marshal(e)
	if err != nil {
		http.Error(w, `{"error":"internal encode error"}`, http.StatusInternalServerError)
		return
	}

	ctx, cancel := context.WithTimeout(r.Context(), storeTimeout)
	defer cancel()
	if err := a.Store.Create(ctx, e.TenantID, e.FeatureName, doc); err != nil {
		if errors.Is(err, storage.ErrDuplicate) {
			http.Error(w, `{"error":"duplicate eventId"}`, http.StatusConflict)
			return
		}
		log.Printf("cosmos create failed: %v", err)
		http.Error(w, `{"error":"failed to store event"}`, http.StatusBadGateway)
		return
	}

	writeJSON(w, http.StatusCreated, map[string]string{"eventId": e.EventID})
}

// tenantIDPattern keeps tenant ids short and safe to put in URLs, logs and
// partition keys: a letter or digit, then letters, digits, ".", "_" or "-".
var tenantIDPattern = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$`)

func validTenantID(id string) bool {
	return tenantIDPattern.MatchString(id)
}

// newID returns a random (version 4) UUID.
func newID() string {
	b := make([]byte, 16)
	_, _ = rand.Read(b)
	b[6] = (b[6] & 0x0f) | 0x40
	b[8] = (b[8] & 0x3f) | 0x80
	return fmt.Sprintf("%x-%x-%x-%x-%x", b[0:4], b[4:6], b[6:8], b[8:10], b[10:16])
}

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(v)
}
