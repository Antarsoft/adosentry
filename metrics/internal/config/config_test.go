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
	_, err = Load(env(map[string]string{}))
	if err == nil {
		t.Fatal("no error with required variables missing")
	}
	for _, name := range []string{"COSMOS_ENDPOINT", "COSMOS_DATABASE", "COSMOS_CONTAINER"} {
		if !strings.Contains(err.Error(), name) {
			t.Errorf("error %q does not name %s", err, name)
		}
	}
	if strings.Contains(err.Error(), "COSMOS_KEY") {
		t.Errorf("error %q names COSMOS_KEY, which is optional", err)
	}
}

func TestAllowedOrigins(t *testing.T) {
	base := map[string]string{"COSMOS_ENDPOINT": "e", "COSMOS_KEY": "k", "COSMOS_DATABASE": "d", "COSMOS_CONTAINER": "c"}
	tests := []struct {
		raw     string
		want    []string
		wantErr bool
	}{
		{"", nil, false},
		{"https://dash.example.com", []string{"https://dash.example.com"}, false},
		{" https://A.example.com , http://localhost:5173,", []string{"https://a.example.com", "http://localhost:5173"}, false},
		{"*", nil, true},
		{"https://a.example.com,*", nil, true},
		{"dash.example.com", nil, true},
		{"https://dash.example.com/", nil, true},
		{"https://dash.example.com/path", nil, true},
		{"ftp://dash.example.com", nil, true},
		{"https://user@dash.example.com", nil, true},
		{"https://*.example.com", nil, true},
	}
	for _, tt := range tests {
		vars := map[string]string{"ALLOWED_ORIGINS": tt.raw}
		for k, v := range base {
			vars[k] = v
		}
		cfg, err := Load(env(vars))
		if (err != nil) != tt.wantErr {
			t.Errorf("%q: err = %v, wantErr %v", tt.raw, err, tt.wantErr)
			continue
		}
		if !tt.wantErr && strings.Join(cfg.AllowedOrigins, "|") != strings.Join(tt.want, "|") {
			t.Errorf("%q: origins = %v, want %v", tt.raw, cfg.AllowedOrigins, tt.want)
		}
	}
}

func TestKeyIsOptional(t *testing.T) {
	cfg, err := Load(env(map[string]string{"COSMOS_ENDPOINT": "e", "COSMOS_DATABASE": "d", "COSMOS_CONTAINER": "c"}))
	if err != nil {
		t.Fatal(err)
	}
	if cfg.Cosmos.Key != "" || !strings.Contains(cfg.Cosmos.AuthMode(), "Entra") {
		t.Errorf("auth mode = %q", cfg.Cosmos.AuthMode())
	}
	cfg.Cosmos.Key = "a2V5"
	if !strings.Contains(cfg.Cosmos.AuthMode(), "COSMOS_KEY") {
		t.Errorf("auth mode with key = %q", cfg.Cosmos.AuthMode())
	}
}
