// AdoSentry metrics API: a small, sender-agnostic ingestion and dashboard
// service in front of Cosmos DB.
//
// Any sender (an Azure DevOps pipeline, a GitHub Action, a cron job, curl)
// posts one JSON event. The envelope is small and fixed; everything
// feature-specific goes in "custom", which Cosmos stores without a schema.
//
// Endpoints:
//
//	POST /events           ingest one event (body up to 64 KB); needs a credential, see AUTH_MODE
//	GET  /metrics/summary  one feature's aggregated numbers; ?feature= (required), ?days= (default 30), ?tenantId= (default "default")
//	GET  /metrics/features the dashboards this deployment exposes
//	GET  /healthz          liveness probe
//	GET  /                 landing page
//	GET  /dashboard        per-feature dashboard; ?feature= (required)
//
// Configuration (environment variables):
//
//	COSMOS_ENDPOINT   e.g. https://your-account.documents.azure.com:443/
//	COSMOS_KEY        optional account key; when unset the service signs in with
//	                  Microsoft Entra ID (DefaultAzureCredential: managed identity in Azure,
//	                  Azure CLI locally; AZURE_CLIENT_ID picks a user-assigned identity)
//	COSMOS_DATABASE   e.g. AIMetrics
//	COSMOS_CONTAINER  e.g. Events
//	PRICING_FILE      optional path to a pricing.json replacing the built-in model rates
//	ALLOWED_ORIGINS   optional comma-separated browser origins allowed to call the API cross-site
//	PORT              default 8080
//
// Authentication for POST /events (the other endpoints are reads; in Azure
// the dashboard and /metrics/* sit behind Container Apps sign-in):
//
//	AUTH_MODE                 required: "entra", "key", "entra,key", or "none" (local
//	                          development only; logs a warning). No default.
//	ENTRA_TENANT_ID           entra: the tenant that issues the tokens
//	ENTRA_AUDIENCE            entra: comma-separated accepted audiences, normally the API
//	                          app's application ID URI (api://...) and its client id
//	ENTRA_ALLOWED_PRINCIPALS  entra, optional: object ids or client app ids allowed to write
//	                          without the Events.Write app role
//	METRICS_API_KEY           key: the shared secret senders put in X-Api-Key, at least 32
//	                          characters (in Azure, a Container Apps secret or Key Vault reference)
//
// An Entra sender sends "Authorization: Bearer <token>" for the API's
// audience, carrying the Events.Write app role; a key sender sends
// "X-Api-Key: <key>". Missing or invalid credentials get 401, a valid token
// without the role gets 403.
//
// The code lives in internal/: config, auth (POST /events), storage
// (Cosmos), summary (aggregation), pricing, handlers (HTTP) and web
// (embedded pages). This
// file only wires them together.
package main

import (
	"context"
	"errors"
	"fmt"
	"log"
	"net/http"
	"os"
	"os/signal"
	"strings"
	"syscall"
	"time"

	"github.com/antarsoft/adosentry/metrics/internal/auth"
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
	log.Printf("cosmos: %s, auth: %s", cfg.Cosmos.Endpoint, cfg.Cosmos.AuthMode())
	writeAuth, err := auth.New(cfg.Auth)
	if err != nil {
		return nil, err
	}
	logAuth(cfg.Auth)
	api := &handlers.API{
		Store:     store,
		Prices:    prices,
		Features:  handlers.KnownFeatures,
		WriteAuth: writeAuth,
	}
	if len(cfg.AllowedOrigins) > 0 {
		log.Printf("cors: allowing %s", strings.Join(cfg.AllowedOrigins, ", "))
	}
	return handlers.CORS(cfg.AllowedOrigins, api.Routes()), nil
}

// logAuth records how POST /events is protected, and shouts when it is not.
func logAuth(a auth.Config) {
	if a.Mode.None {
		for range 3 {
			log.Printf("WARNING: AUTH_MODE=none: POST /events accepts writes from anyone. Use this only for local development.")
		}
		return
	}
	msg := "auth: POST /events requires " + a.Mode.String()
	if a.Mode.Entra {
		msg += fmt.Sprintf(" (tenant %s, audience %s, role %s", a.TenantID, strings.Join(a.Audiences, " or "), auth.WriteRole)
		if len(a.AllowedPrincipals) > 0 {
			msg += fmt.Sprintf(" or one of %d allowed principal(s)", len(a.AllowedPrincipals))
		}
		msg += ")"
	}
	log.Print(msg)
}
