package pricing

import (
	"math"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"
)

func TestDefaultRates(t *testing.T) {
	// The embedded file must keep the rates the service shipped with.
	want := map[string]Rate{
		"gpt-5-mini":   {InputPerMillion: 0.25, OutputPerMillion: 2.00},
		"gpt-5.4-mini": {InputPerMillion: 0.75, OutputPerMillion: 4.50},
		"gpt-5.6-luna": {InputPerMillion: 0.20, OutputPerMillion: 1.20},
	}
	got := Default()
	if !slices.Equal(got.Models(), []string{"gpt-5-mini", "gpt-5.4-mini", "gpt-5.6-luna"}) {
		t.Fatalf("models = %v", got.Models())
	}
	for model, rate := range want {
		if got.rates[model] != rate {
			t.Errorf("%s = %+v, want %+v", model, got.rates[model], rate)
		}
	}
}

func TestEstimateUSD(t *testing.T) {
	table := Default()
	tests := []struct {
		name               string
		model              string
		prompt, completion float64
		want               float64
	}{
		{"one million prompt tokens", "gpt-5-mini", 1_000_000, 0, 0.25},
		{"one million completion tokens", "gpt-5-mini", 0, 1_000_000, 2.00},
		{"mixed", "gpt-5.4-mini", 120_000, 30_000, 0.09 + 0.135},
		{"small run", "gpt-5.6-luna", 2_000, 500, 0.0004 + 0.0006},
		{"no tokens", "gpt-5-mini", 0, 0, 0},
		{"unknown model costs nothing", "gpt-9-ultra", 1_000_000, 1_000_000, 0},
		{"empty model costs nothing", "", 1_000_000, 1_000_000, 0},
		{"model names are case sensitive", "GPT-5-MINI", 1_000_000, 0, 0},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := table.EstimateUSD(tt.model, tt.prompt, tt.completion)
			if math.Abs(got-tt.want) > 1e-12 {
				t.Errorf("EstimateUSD(%q, %v, %v) = %v, want %v", tt.model, tt.prompt, tt.completion, got, tt.want)
			}
		})
	}
	if got := (Table{}).EstimateUSD("gpt-5-mini", 1e6, 1e6); got != 0 {
		t.Errorf("zero Table priced a run at %v", got)
	}
}

func TestParse(t *testing.T) {
	tests := []struct {
		name    string
		doc     string
		wantErr string
		models  []string
	}{
		{"valid", `{"models":{"m":{"inputPerMillion":1,"outputPerMillion":2}}}`, "", []string{"m"}},
		{"empty models is allowed", `{"models":{}}`, "", []string{}},
		{"free model", `{"models":{"local":{"inputPerMillion":0,"outputPerMillion":0}}}`, "", []string{"local"}},
		{"missing models", `{}`, `missing "models"`, nil},
		{"unknown field", `{"models":{"m":{"inputPerMilion":1}}}`, "unknown field", nil},
		{"unknown top-level field", `{"models":{},"currency":"EUR"}`, "unknown field", nil},
		{"negative rate", `{"models":{"m":{"inputPerMillion":-1,"outputPerMillion":2}}}`, "zero or positive", nil},
		{"empty model name", `{"models":{"":{"inputPerMillion":1,"outputPerMillion":2}}}`, "must not be empty", nil},
		{"rate as string", `{"models":{"m":{"inputPerMillion":"1"}}}`, "invalid JSON", nil},
		{"not JSON", `models: {}`, "invalid JSON", nil},
		{"trailing data", `{"models":{}} {}`, "trailing data", nil},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got, err := Parse([]byte(tt.doc))
			if tt.wantErr != "" {
				if err == nil || !strings.Contains(err.Error(), tt.wantErr) {
					t.Fatalf("err = %v, want it to mention %q", err, tt.wantErr)
				}
				return
			}
			if err != nil {
				t.Fatal(err)
			}
			if !slices.Equal(got.Models(), tt.models) {
				t.Errorf("models = %v, want %v", got.Models(), tt.models)
			}
		})
	}
}

func TestLoad(t *testing.T) {
	dir := t.TempDir()
	custom := filepath.Join(dir, "pricing.json")
	if err := os.WriteFile(custom, []byte(`{"models":{"my-deployment":{"inputPerMillion":1,"outputPerMillion":3}}}`), 0o600); err != nil {
		t.Fatal(err)
	}
	broken := filepath.Join(dir, "broken.json")
	if err := os.WriteFile(broken, []byte(`{"models":`), 0o600); err != nil {
		t.Fatal(err)
	}

	def, err := Load("")
	if err != nil || len(def.Models()) != 3 {
		t.Fatalf("Load(\"\") = %v, %v; want the defaults", def.Models(), err)
	}

	got, err := Load(custom)
	if err != nil {
		t.Fatal(err)
	}
	// A pricing file replaces the defaults; it does not merge with them.
	if !slices.Equal(got.Models(), []string{"my-deployment"}) {
		t.Errorf("models = %v", got.Models())
	}
	if got.EstimateUSD("gpt-5-mini", 1e6, 0) != 0 {
		t.Error("default model still priced after loading a pricing file")
	}

	if _, err := Load(broken); err == nil || !strings.Contains(err.Error(), broken) {
		t.Errorf("broken file: err = %v, want it to name the file", err)
	}
	if _, err := Load(filepath.Join(dir, "missing.json")); err == nil {
		t.Error("missing file: no error")
	}
}
