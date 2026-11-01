// Package config reads the service's settings from environment variables.
package config

import (
	"errors"
	"fmt"
	"net/url"
	"strings"

	"github.com/antarsoft/pullpicket/metrics/internal/auth"
	"github.com/antarsoft/pullpicket/metrics/internal/storage"
)

// Config is everything main needs to start the service.
type Config struct {
	Port        string
	Cosmos      storage.CosmosConfig
	PricingFile string
	// AllowedOrigins are the browser origins allowed to call the API
	// cross-site (CORS). Empty means same-origin only.
	AllowedOrigins []string
	// Auth guards POST /events.
	Auth auth.Config
}

// Load reads the settings through getenv (os.Getenv in production). It
// reports every missing required variable at once.
func Load(getenv func(string) string) (Config, error) {
	var missing []string
	require := func(name string) string {
		v := getenv(name)
		if v == "" {
			missing = append(missing, name)
		}
		return v
	}
	cfg := Config{
		Port: getenv("PORT"),
		Cosmos: storage.CosmosConfig{
			Endpoint:  require("COSMOS_ENDPOINT"),
			Key:       getenv("COSMOS_KEY"), // optional: unset means Entra ID
			Database:  require("COSMOS_DATABASE"),
			Container: require("COSMOS_CONTAINER"),
		},
		PricingFile: getenv("PRICING_FILE"),
	}
	if len(missing) > 0 {
		return Config{}, fmt.Errorf("missing required environment variable(s): %s", strings.Join(missing, ", "))
	}
	if cfg.Port == "" {
		cfg.Port = "8080"
	}
	origins, err := parseOrigins(getenv("ALLOWED_ORIGINS"))
	if err != nil {
		return Config{}, err
	}
	cfg.AllowedOrigins = origins

	mode, err := auth.ParseMode(getenv("AUTH_MODE"))
	if err != nil {
		return Config{}, err
	}
	cfg.Auth = auth.Config{
		Mode:              mode,
		TenantID:          strings.TrimSpace(getenv("ENTRA_TENANT_ID")),
		Audiences:         splitList(getenv("ENTRA_AUDIENCE")),
		AllowedPrincipals: splitList(getenv("ENTRA_ALLOWED_PRINCIPALS")),
		APIKey:            getenv("METRICS_API_KEY"),
	}
	if err := cfg.Auth.Validate(); err != nil {
		return Config{}, err
	}
	return cfg, nil
}

// splitList reads a comma-separated list, dropping blanks.
func splitList(raw string) []string {
	var out []string
	for _, part := range strings.Split(raw, ",") {
		if v := strings.TrimSpace(part); v != "" {
			out = append(out, v)
		}
	}
	return out
}

// parseOrigins reads a comma-separated list such as
// "https://a.example.com, https://b.example.com:8443". Each entry must be a
// bare http(s) origin: no path, query or wildcard.
func parseOrigins(raw string) ([]string, error) {
	var out []string
	for _, part := range strings.Split(raw, ",") {
		o := strings.TrimSpace(part)
		if o == "" {
			continue
		}
		if strings.Contains(o, "*") {
			return nil, errors.New("ALLOWED_ORIGINS: wildcards are not allowed; list each origin")
		}
		u, err := url.Parse(o)
		if err != nil || (u.Scheme != "https" && u.Scheme != "http") || u.Host == "" || u.Path != "" || u.RawQuery != "" || u.Fragment != "" || u.User != nil {
			return nil, fmt.Errorf("ALLOWED_ORIGINS: %q is not an origin such as https://dashboard.example.com", o)
		}
		out = append(out, strings.ToLower(u.Scheme)+"://"+strings.ToLower(u.Host))
	}
	return out, nil
}
