// AdoSentry metrics API: a small, sender-agnostic ingestion and dashboard
// service in front of Cosmos DB.
//
// Any sender (an Azure DevOps pipeline, a GitHub Action, a cron job, curl)
// posts one JSON event. The envelope is small and fixed; everything
// feature-specific goes in "custom", which Cosmos stores without a schema.
//
// Endpoints:
//
//	POST /events           ingest one event (body up to 64 KB)
//	GET  /metrics/summary  one feature's aggregated numbers; ?feature= (required), ?days= (default 30), ?tenantId= (default "default")
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
//	ALLOWED_ORIGINS   optional comma-separated browser origins allowed to call the API cross-site
//	PORT              default 8080
//
// The code lives in internal/: config, storage (Cosmos), summary
// (aggregation), pricing, handlers (HTTP) and web (embedded pages). This
// file only wires them together.
package main

import (
	"context"
	"errors"
	"log"
	"net/http"
	"os"
	"os/signal"
	"strings"
	"syscall"
	"time"

	"github.com/antarsoft/adosentry/metrics/internal/config"
	"github.com/antarsoft/adosentry/metrics/internal/handlers"
	"github.com/antarsoft/adosentry/metrics/internal/pricing"
	"github.com/antarsoft/adosentry/metrics/internal/storage"
)

// shutdownGrace is how long in-flight requests get after SIGTERM.
const shutdownGrace = 20 * time.Second

func main() {
	cfg, err := config.Load(os.Getenv)
	if err != nil {
		log.Fatal(err)
	}
	handler, err := newHandler(cfg)
	if err != nil {
		log.Fatal(err)
	}
	srv := newServer(":"+cfg.Port, handler)

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	go func() {
		<-ctx.Done()
		shutdownCtx, cancel := context.WithTimeout(context.Background(), shutdownGrace)
		defer cancel()
		if err := srv.Shutdown(shutdownCtx); err != nil {
			log.Printf("shutdown: %v", err)
		}
	}()

	log.Printf("ai-metrics-api listening on %s", srv.Addr)
	if err := srv.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
		log.Fatal(err)
	}
}

// newServer sets every timeout, so a slow or stalled client cannot hold a
// connection open indefinitely. WriteTimeout leaves room for the summary's
// 15-second Cosmos query.
func newServer(addr string, handler http.Handler) *http.Server {
	return &http.Server{
		Addr:              addr,
		Handler:           handler,
		ReadHeaderTimeout: 5 * time.Second,
		ReadTimeout:       15 * time.Second,
		WriteTimeout:      30 * time.Second,
		IdleTimeout:       120 * time.Second,
		MaxHeaderBytes:    64 << 10,
	}
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
	if len(cfg.AllowedOrigins) > 0 {
		log.Printf("cors: allowing %s", strings.Join(cfg.AllowedOrigins, ", "))
	}
	return handlers.CORS(cfg.AllowedOrigins, api.Routes()), nil
}
