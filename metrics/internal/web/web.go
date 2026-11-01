// Package web holds the dashboard pages, compiled into the binary.
package web

import (
	"embed"
	"net/http"
)

//go:embed index.html dashboard.html
var files embed.FS

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
