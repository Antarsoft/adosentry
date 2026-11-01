package handlers

import (
	"context"
	"log"
	"net/http"
	"strconv"
	"time"

	"github.com/antarsoft/pullpicket/metrics/internal/storage"
	"github.com/antarsoft/pullpicket/metrics/internal/summary"
)

const (
	defaultWindowDays = 30
	queryTimeout      = 15 * time.Second
)

// handleSummary serves GET /metrics/summary?feature=<name>&days=<n>&tenantId=<id>.
// days defaults to 30; anything that is not a positive integer means 30.
// tenantId defaults to "default".
func (a *API) handleSummary(w http.ResponseWriter, r *http.Request) {
	feature := r.URL.Query().Get("feature")
	if feature == "" {
		http.Error(w, `{"error":"feature query param is required"}`, http.StatusBadRequest)
		return
	}
	if !a.isKnownFeature(feature) {
		http.Error(w, `{"error":"unknown feature"}`, http.StatusNotFound)
		return
	}
	tenantID := r.URL.Query().Get("tenantId")
	if tenantID == "" {
		tenantID = storage.DefaultTenant
	}
	if !validTenantID(tenantID) {
		http.Error(w, `{"error":"invalid tenantId"}`, http.StatusBadRequest)
		return
	}
	days := defaultWindowDays
	if d := r.URL.Query().Get("days"); d != "" {
		if parsed, err := strconv.Atoi(d); err == nil && parsed > 0 {
			days = parsed
		}
	}
	sinceTime := a.now().UTC().AddDate(0, 0, -days)
	since := sinceTime.Format(time.RFC3339)

	ctx, cancel := context.WithTimeout(r.Context(), queryTimeout)
	defer cancel()

	agg := summary.New(feature, days, sinceTime, a.Prices)
	err := a.Store.EachRow(ctx, tenantID, feature, since, func(row storage.Row) error {
		agg.Add(row)
		return nil
	})
	if err != nil {
		log.Printf("cosmos query failed: %v", err)
		http.Error(w, `{"error":"failed to query metrics"}`, http.StatusBadGateway)
		return
	}
	writeJSON(w, http.StatusOK, agg.Result(a.now()))
}
