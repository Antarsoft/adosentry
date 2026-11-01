// AdoSentry metrics API: a small, sender-agnostic ingestion and dashboard
// service in front of Cosmos DB.
//
// Any sender (an Azure DevOps pipeline, a GitHub Action, a cron job, curl)
// posts one JSON event. The envelope is small and fixed; everything
// feature-specific goes in "custom", which Cosmos stores without a schema.
//
// Endpoints:
//
//	POST /events           ingest one event
//	GET  /metrics/summary  one feature's aggregated numbers; ?feature= (required), ?days= (default 30)
//	GET  /metrics/features the dashboards this deployment exposes
//	GET  /healthz          liveness probe
//	GET  /                 landing page
//	GET  /dashboard        per-feature dashboard; ?feature= (required)
//
// Configuration (environment variables):
//
//	COSMOS_ENDPOINT   e.g. https://your-account.documents.azure.com:443/
//	COSMOS_KEY        Cosmos DB account key
//	COSMOS_DATABASE   e.g. AIMetrics
//	COSMOS_CONTAINER  e.g. Events
//	PRICING_FILE      optional path to a pricing.json replacing the built-in model rates
//	PORT              default 8080
//
// The code lives in internal/: config, storage (Cosmos), summary
// (aggregation), pricing, handlers (HTTP) and web (embedded pages). This
// file only wires them together.
package main

import (
	"log"
	"net/http"
	"os"
	"strings"

	"github.com/antarsoft/adosentry/metrics/internal/config"
	"github.com/antarsoft/adosentry/metrics/internal/handlers"
	"github.com/antarsoft/adosentry/metrics/internal/pricing"
	"github.com/antarsoft/adosentry/metrics/internal/storage"
)

func main() {
	cfg, err := config.Load(os.Getenv)
	if err != nil {
		log.Fatal(err)
	}
	handler, err := newHandler(cfg)
	if err != nil {
		log.Fatal(err)
	}
	log.Printf("ai-metrics-api listening on :%s", cfg.Port)
	log.Fatal(http.ListenAndServe(":"+cfg.Port, handler))
}

// newHandler builds the full service from its configuration; main and the
// characterisation tests share it.
func newHandler(cfg config.Config) (http.Handler, error) {
	prices, err := pricing.Load(cfg.PricingFile)
	if err != nil {
		return nil, err
	}
	log.Printf("pricing: %d model(s): %s", len(prices.Models()), strings.Join(prices.Models(), ", "))

	store, err := storage.OpenCosmos(cfg.Cosmos)
	if err != nil {
		return nil, err
	}
	api := &handlers.API{
		Store:    store,
		Prices:   prices,
		Features: handlers.KnownFeatures,
	}
	return handlers.WithCORS(api.Routes()), nil
}
