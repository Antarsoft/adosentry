package web

import (
	"crypto/sha256"
	"encoding/hex"
	"strings"
	"testing"
)

func TestChartJSMatchesPinnedHash(t *testing.T) {
	b, err := files.ReadFile("static/chart.umd.min.js")
	if err != nil {
		t.Fatal(err)
	}
	sum := sha256.Sum256(b)
	if got := hex.EncodeToString(sum[:]); got != ChartJSSHA256 {
		t.Errorf("static/chart.umd.min.js sha256 = %s, want %s", got, ChartJSSHA256)
	}
}

func TestPagesLoadNothingFromOtherOrigins(t *testing.T) {
	for _, name := range []string{"index.html", "dashboard.html"} {
		b, err := files.ReadFile(name)
		if err != nil {
			t.Fatal(err)
		}
		for _, needle := range []string{`src="http`, `src='http`, `href="http`, "cdnjs", "jsdelivr", "unpkg"} {
			if strings.Contains(string(b), needle) {
				t.Errorf("%s contains %q", name, needle)
			}
		}
	}
}
