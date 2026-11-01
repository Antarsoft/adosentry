// Package web holds the dashboard pages and their scripts, compiled into
// the binary.
//
// static/chart.umd.min.js is Chart.js 4.5.0 (MIT licence, header kept in the
// file), served from the API's own origin so the dashboard loads nothing
// from a CDN. To upgrade it, replace the file with the new release's
// dist/chart.umd.min.js and update ChartJSSHA256 below; a test checks the
// two match.
package web

import (
	"embed"
	"io/fs"
	"net/http"
	"strings"
)

//go:embed index.html dashboard.html static
var files embed.FS

// ChartJSSHA256 is the SHA-256 of static/chart.umd.min.js as published on
// npm (chart.js@4.5.0, dist/chart.umd.min.js).
const ChartJSSHA256 = "2f27bcf471b2d69dd78494f6e2172fb28470eb843820e2f96bb85d39f9618d30"

// Page returns a handler that serves one embedded HTML page.
func Page(name string) http.HandlerFunc {
	b, err := files.ReadFile(name)
	if err != nil {
		panic("web: no embedded page " + name)
	}
	return func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/html; charset=utf-8")
		_, _ = w.Write(b)
	}
}

// Static serves the embedded static/ directory; mount it at /static/.
func Static() http.Handler {
	sub, err := fs.Sub(files, "static")
	if err != nil {
		panic(err)
	}
	fileServer := http.StripPrefix("/static/", http.FileServerFS(sub))
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodGet && r.Method != http.MethodHead {
			http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
			return
		}
		if strings.HasSuffix(r.URL.Path, "/") {
			http.NotFound(w, r) // no directory listings
			return
		}
		// Files change only with a new image; a day of caching is plenty.
		w.Header().Set("Cache-Control", "public, max-age=86400")
		fileServer.ServeHTTP(w, r)
	})
}
