package handlers

import (
	"net/http"
	"slices"
)

// CORS lets the listed browser origins call the API from other sites. The
// dashboard is served from the API's own origin and senders are not
// browsers, so neither needs CORS. With no origins listed (the default) the
// handler is returned unchanged and browsers apply the same-origin policy.
//
// There is no wildcard: config rejects "*".
func CORS(allowedOrigins []string, h http.Handler) http.Handler {
	if len(allowedOrigins) == 0 {
		return h
	}
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Add("Vary", "Origin")
		origin := r.Header.Get("Origin")
		if origin == "" || !slices.Contains(allowedOrigins, origin) {
			h.ServeHTTP(w, r)
			return
		}
		w.Header().Set("Access-Control-Allow-Origin", origin)
		if r.Method == http.MethodOptions && r.Header.Get("Access-Control-Request-Method") != "" {
			w.Header().Set("Access-Control-Allow-Headers", "Content-Type, Authorization, X-Api-Key")
			w.Header().Set("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
			w.Header().Set("Access-Control-Max-Age", "600")
			w.WriteHeader(http.StatusNoContent)
			return
		}
		h.ServeHTTP(w, r)
	})
}
