package config

import (
	"strings"
	"testing"
)

func env(m map[string]string) func(string) string {
	return func(k string) string { return m[k] }
}

func TestLoad(t *testing.T) {
	full := map[string]string{
		"COSMOS_ENDPOINT":  "https://acct.documents.azure.com:443/",
		"COSMOS_KEY":       "a2V5",
		"COSMOS_DATABASE":  "AIMetrics",
		"COSMOS_CONTAINER": "Events",
	}
	cfg, err := Load(env(full))
	if err != nil {
		t.Fatal(err)
	}
	if cfg.Port != "8080" || cfg.PricingFile != "" {
		t.Errorf("defaults: %+v", cfg)
	}
	if cfg.Cosmos.Endpoint != full["COSMOS_ENDPOINT"] || cfg.Cosmos.Key != "a2V5" || cfg.Cosmos.Database != "AIMetrics" || cfg.Cosmos.Container != "Events" {
		t.Errorf("cosmos: %+v", cfg.Cosmos)
	}

	full["PORT"] = "9090"
	full["PRICING_FILE"] = "/etc/adosentry/pricing.json"
	cfg, err = Load(env(full))
	if err != nil || cfg.Port != "9090" || cfg.PricingFile != "/etc/adosentry/pricing.json" {
		t.Errorf("overrides: %+v, %v", cfg, err)
	}
}

func TestLoadMissing(t *testing.T) {
	_, err := Load(env(map[string]string{"COSMOS_KEY": "a2V5"}))
	if err == nil {
		t.Fatal("no error with required variables missing")
	}
	for _, name := range []string{"COSMOS_ENDPOINT", "COSMOS_DATABASE", "COSMOS_CONTAINER"} {
		if !strings.Contains(err.Error(), name) {
			t.Errorf("error %q does not name %s", err, name)
		}
	}
	if strings.Contains(err.Error(), "COSMOS_KEY") {
		t.Errorf("error %q names COSMOS_KEY, which was set", err)
	}
}
