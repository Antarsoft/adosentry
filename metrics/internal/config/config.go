// Package config reads the service's settings from environment variables.
package config

import (
	"fmt"
	"strings"

	"github.com/antarsoft/adosentry/metrics/internal/storage"
)

// Config is everything main needs to start the service.
type Config struct {
	Port        string
	Cosmos      storage.CosmosConfig
	PricingFile string
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
			Key:       require("COSMOS_KEY"),
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
	return cfg, nil
}
