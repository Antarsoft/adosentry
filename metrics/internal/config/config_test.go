package config

import (
	"slices"
	"strings"
	"testing"

	"github.com/antarsoft/pullpicket/metrics/internal/auth"
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
		"AUTH_MODE":        "none",
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
	full["PRICING_FILE"] = "/etc/pullpicket/pricing.json"
	cfg, err = Load(env(full))
	if err != nil || cfg.Port != "9090" || cfg.PricingFile != "/etc/pullpicket/pricing.json" {
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
	base := map[string]string{"COSMOS_ENDPOINT": "e", "COSMOS_KEY": "k", "COSMOS_DATABASE": "d", "COSMOS_CONTAINER": "c", "AUTH_MODE": "none"}
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
	cfg, err := Load(env(map[string]string{"COSMOS_ENDPOINT": "e", "COSMOS_DATABASE": "d", "COSMOS_CONTAINER": "c", "AUTH_MODE": "none"}))
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

// TestAuthSettings: AUTH_MODE has no default, and each mode needs its own
// settings before the service will start.
func TestAuthSettings(t *testing.T) {
	key := strings.Repeat("k", auth.MinKeyLength)
	tenant := "11111111-2222-3333-4444-555555555555"
	tests := []struct {
		name    string
		vars    map[string]string
		wantErr string // substring; empty means no error
		check   func(t *testing.T, a auth.Config)
	}{
		{name: "AUTH_MODE unset", vars: map[string]string{}, wantErr: "AUTH_MODE is required"},
		{name: "unknown mode", vars: map[string]string{"AUTH_MODE": "basic"}, wantErr: "unknown value"},
		{name: "none with key", vars: map[string]string{"AUTH_MODE": "none,key"}, wantErr: "cannot be combined"},
		{name: "none", vars: map[string]string{"AUTH_MODE": " NONE "}, check: func(t *testing.T, a auth.Config) {
			if !a.Mode.None || a.Mode.String() != "none" {
				t.Errorf("mode = %+v", a.Mode)
			}
		}},
		{name: "key without a key", vars: map[string]string{"AUTH_MODE": "key"}, wantErr: "METRICS_API_KEY is required"},
		{name: "short key", vars: map[string]string{"AUTH_MODE": "key", "METRICS_API_KEY": "short"}, wantErr: "at least 32"},
		{name: "key", vars: map[string]string{"AUTH_MODE": "key", "METRICS_API_KEY": key}, check: func(t *testing.T, a auth.Config) {
			if !a.Mode.Key || a.Mode.Entra || a.APIKey != key {
				t.Errorf("auth = %+v", a)
			}
		}},
		{name: "entra without settings", vars: map[string]string{"AUTH_MODE": "entra"}, wantErr: "ENTRA_TENANT_ID is required"},
		{name: "entra without audience", vars: map[string]string{"AUTH_MODE": "entra", "ENTRA_TENANT_ID": tenant}, wantErr: "ENTRA_AUDIENCE is required"},
		{name: "entra", vars: map[string]string{
			"AUTH_MODE": "entra", "ENTRA_TENANT_ID": tenant,
			"ENTRA_AUDIENCE": "api://pullpicket-metrics, 6f1c0000-0000-0000-0000-000000000000", "ENTRA_ALLOWED_PRINCIPALS": "oid-1,,oid-2",
		}, check: func(t *testing.T, a auth.Config) {
			if !a.Mode.Entra || a.Mode.Key || a.TenantID != tenant {
				t.Errorf("auth = %+v", a)
			}
			if !slices.Equal(a.Audiences, []string{"api://pullpicket-metrics", "6f1c0000-0000-0000-0000-000000000000"}) {
				t.Errorf("audiences = %q", a.Audiences)
			}
			if !slices.Equal(a.AllowedPrincipals, []string{"oid-1", "oid-2"}) {
				t.Errorf("principals = %q", a.AllowedPrincipals)
			}
		}},
		{name: "both needs both", vars: map[string]string{"AUTH_MODE": "key,entra", "METRICS_API_KEY": key}, wantErr: "ENTRA_TENANT_ID"},
		{name: "both", vars: map[string]string{"AUTH_MODE": "key,entra", "METRICS_API_KEY": key, "ENTRA_TENANT_ID": tenant, "ENTRA_AUDIENCE": "api://x"}, check: func(t *testing.T, a auth.Config) {
			if a.Mode.String() != "entra,key" {
				t.Errorf("mode = %q", a.Mode)
			}
		}},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			vars := map[string]string{"COSMOS_ENDPOINT": "e", "COSMOS_DATABASE": "d", "COSMOS_CONTAINER": "c"}
			for k, v := range tt.vars {
				vars[k] = v
			}
			cfg, err := Load(env(vars))
			if tt.wantErr != "" {
				if err == nil || !strings.Contains(err.Error(), tt.wantErr) {
					t.Fatalf("err = %v, want one containing %q", err, tt.wantErr)
				}
				return
			}
			if err != nil {
				t.Fatal(err)
			}
			tt.check(t, cfg.Auth)
		})
	}
}
