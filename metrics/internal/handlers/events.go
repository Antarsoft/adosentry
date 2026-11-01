package handlers

import (
	"context"
	"crypto/rand"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"net/http"
	"time"

	"github.com/antarsoft/adosentry/metrics/internal/storage"
)

// storeTimeout bounds one Cosmos write.
const storeTimeout = 10 * time.Second

// Event is the envelope every sender uses. Only FeatureName is required.
// Everything feature-specific (repository, prId, commentsCount, tokens, and
// whatever a future feature needs) goes in Custom, which is deliberately
// untyped so it can change without a schema migration.
type Event struct {
	ID             string         `json:"id"` // Cosmos document id, always equal to EventID
	EventID        string         `json:"eventId"`
	Timestamp      string         `json:"timestamp"`   // event time (RFC3339); the server fills it in if omitted
	ReceivedAt     string         `json:"receivedAt"`  // server receipt time, always set by the server
	FeatureName    string         `json:"featureName"` // required; partition key; e.g. "ai-code-review"
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
	if err := json.NewDecoder(r.Body).Decode(&e); err != nil {
		http.Error(w, fmt.Sprintf(`{"error":"invalid JSON: %s"}`, err), http.StatusBadRequest)
		return
	}
	if e.FeatureName == "" {
		http.Error(w, `{"error":"featureName is required"}`, http.StatusBadRequest)
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
	if err := a.Store.Create(ctx, e.FeatureName, doc); err != nil {
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
