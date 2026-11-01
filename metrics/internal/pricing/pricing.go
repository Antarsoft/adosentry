// Package pricing turns token counts into an estimated USD cost.
//
// Rates are USD per 1,000,000 tokens, keyed by the `model` field each event
// carries (for ai-code-review, the deployment name the stage sends). Cost is
// computed per event with that event's own model, so changing models never
// rewrites history: add an entry for the new model. A model with no entry
// costs $0; its tokens still count.
//
// completionTokens already includes reasoningTokens as a billed subset, so it
// is priced once at the output rate and reasoning is never added on top.
//
// cachedTokens (a subset of promptTokens) is not discounted: the full
// promptTokens is charged at the input rate, which makes totals an upper
// bound for features with a high cache hit rate. Add a cached-input rate
// only once the discount is confirmed from Azure OpenAI / Foundry billing.
//
// The defaults live in pricing.json next to this file and are compiled into
// the binary. PRICING_FILE points at a replacement file with the same shape;
// it replaces the defaults entirely rather than merging with them.
package pricing

import (
	"bytes"
	_ "embed"
	"encoding/json"
	"errors"
	"fmt"
	"math"
	"os"
	"sort"
)

//go:embed pricing.json
var defaultFile []byte

// Rate is the price of one model.
type Rate struct {
	InputPerMillion  float64 `json:"inputPerMillion"`  // $ per 1,000,000 prompt tokens
	OutputPerMillion float64 `json:"outputPerMillion"` // $ per 1,000,000 completion tokens (includes reasoning)
}

// Table maps a model name to its rate. The zero value prices everything at $0.
type Table struct {
	rates map[string]Rate
}

type fileFormat struct {
	Models map[string]Rate `json:"models"`
}

// Default returns the rates compiled into the binary.
func Default() Table {
	t, err := Parse(defaultFile)
	if err != nil {
		panic(fmt.Sprintf("embedded pricing.json is invalid: %v", err))
	}
	return t
}

// Load returns the rates in the file at path, or the defaults when path is
// empty.
func Load(path string) (Table, error) {
	if path == "" {
		return Default(), nil
	}
	b, err := os.ReadFile(path)
	if err != nil {
		return Table{}, fmt.Errorf("read pricing file: %w", err)
	}
	t, err := Parse(b)
	if err != nil {
		return Table{}, fmt.Errorf("pricing file %s: %w", path, err)
	}
	return t, nil
}

// Parse reads a pricing document. Unknown fields, a missing "models" object,
// empty model names and negative or non-finite rates are errors, so a typo
// fails at startup instead of quietly pricing a model at $0.
func Parse(b []byte) (Table, error) {
	dec := json.NewDecoder(bytes.NewReader(b))
	dec.DisallowUnknownFields()
	var f fileFormat
	if err := dec.Decode(&f); err != nil {
		return Table{}, fmt.Errorf("invalid JSON: %w", err)
	}
	if dec.More() {
		return Table{}, errors.New("invalid JSON: trailing data after the top-level object")
	}
	if f.Models == nil {
		return Table{}, errors.New(`missing "models" object`)
	}
	for name, r := range f.Models {
		if name == "" {
			return Table{}, errors.New("model name must not be empty")
		}
		for _, v := range []float64{r.InputPerMillion, r.OutputPerMillion} {
			if v < 0 || math.IsNaN(v) || math.IsInf(v, 0) {
				return Table{}, fmt.Errorf("model %q: rates must be zero or positive numbers", name)
			}
		}
	}
	return Table{rates: f.Models}, nil
}

// EstimateUSD prices one event. An unknown model costs 0.
func (t Table) EstimateUSD(model string, promptTokens, completionTokens float64) float64 {
	r, ok := t.rates[model]
	if !ok {
		return 0
	}
	return (promptTokens/1_000_000)*r.InputPerMillion + (completionTokens/1_000_000)*r.OutputPerMillion
}

// Models lists the priced model names in order, for the startup log.
func (t Table) Models() []string {
	out := make([]string, 0, len(t.rates))
	for name := range t.rates {
		out = append(out, name)
	}
	sort.Strings(out)
	return out
}
