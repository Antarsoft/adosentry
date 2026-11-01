// Package handlers is the HTTP surface of the metrics service.
//
// Routes registers each endpoint on its own line, so middleware can wrap a
// single route (authentication on POST /events, for instance) without
// touching the handlers themselves.
package handlers

import (
	"net/http"
	"slices"
	"time"

	"github.com/antarsoft/adosentry/metrics/internal/pricing"
	"github.com/antarsoft/adosentry/metrics/internal/storage"
	"github.com/antarsoft/adosentry/metrics/internal/web"
)

// API holds what the handlers need.
type API struct {
	Store  storage.Store
	Prices pricing.Table
	// Features is the curated list of dashboards this deployment exposes.
	// featureName values are never discovered from Cosmos, so stray or test
	// documents never get a landing-page entry or a working summary.
	Features []string
	// Now is the clock; nil means time.Now.
	Now func() time.Time
}

// KnownFeatures is the default Features list. Adding a dashboard for a new
// AI feature means adding its featureName here deliberately.
var KnownFeatures = []string{
	"ai-code-review",
}

// Routes returns the router with every endpoint registered.
func (a *API) Routes() *http.ServeMux {
	mux := http.NewServeMux()
	mux.HandleFunc("/healthz", a.handleHealth)
	mux.HandleFunc("/events", a.handleEvents)
	mux.HandleFunc("/metrics/summary", a.handleSummary)
	mux.HandleFunc("/metrics/features", a.handleFeatures)
	mux.HandleFunc("/dashboard", web.Page("dashboard.html"))
	mux.HandleFunc("/", a.handleIndex(web.Page("index.html")))
	return mux
}

func (a *API) now() time.Time {
	if a.Now != nil {
		return a.Now()
	}
	return time.Now()
}

func (a *API) isKnownFeature(name string) bool {
	return slices.Contains(a.Features, name)
}

func (a *API) handleHealth(w http.ResponseWriter, r *http.Request) {
	w.WriteHeader(http.StatusOK)
	_, _ = w.Write([]byte("ok"))
}

// handleIndex serves the landing page at "/" only; "/" is also the
// catch-all pattern, so every other unmatched path is a 404.
func (a *API) handleIndex(page http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/" {
			http.NotFound(w, r)
			return
		}
		page(w, r)
	}
}

// handleFeatures lists the dashboards for the landing page. It reads the
// static Features list, not Cosmos: no cross-partition scan, and no stray
// documents showing up as their own dashboard.
func (a *API) handleFeatures(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, http.StatusOK, map[string][]string{"features": a.Features})
}
