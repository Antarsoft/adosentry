// AI Metrics ingestion API — thin, sender-agnostic layer in front of Cosmos DB.
//
// Design goals (least headache, upgradable, agnostic, dynamic):
//   - Any sender (ADO pipeline, GitHub Action, a Slack bot, a cron job, curl)
//     can emit an event with a single POST + API key header. No SDKs, no
//     per-language client libraries required.
//   - The event envelope is small and fixed (id, time, featureName, source).
//     Everything feature-specific lives in "custom" -- a free-form JSON
//     object. Cosmos DB has no schema to fight, so this costs nothing.
//   - Storage/dashboard can be upgraded later (Cosmos DB Synapse Link -> Power
//     BI / Synapse serverless SQL) without touching the capture contract or
//     re-sending historical data.
//
// Endpoints:
//
//	POST /events           - ingest one event (public, no auth)
//	GET  /metrics/summary  - aggregated numbers for one feature's dashboard (feature must be in knownFeatures)
//	                         query params: feature (required), days (optional, default 30)
//	GET  /metrics/features - the knownFeatures list, for the landing page
//	GET  /healthz           - liveness probe
//	GET  /                  - landing page listing every known feature with metrics
//	GET  /dashboard         - per-feature dashboard; query param: feature (required)
//
// Config via environment variables:
//
//	COSMOS_ENDPOINT      - e.g. https://your-account.documents.azure.com:443/
//	COSMOS_KEY           - Cosmos DB primary or secondary key
//	COSMOS_DATABASE      - e.g. AIMetrics
//	COSMOS_CONTAINER     - e.g. Events
//	PORT                 - default 8080
package main

import (
	"context"
	"crypto/rand"
	"embed"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"net/http"
	"os"
	"slices"
	"sort"
	"strconv"
	"strings"
	"time"

	"github.com/Azure/azure-sdk-for-go/sdk/azcore"
	"github.com/Azure/azure-sdk-for-go/sdk/azcore/runtime"
	"github.com/Azure/azure-sdk-for-go/sdk/data/azcosmos"
)

//go:embed index.html dashboard.html
var embeddedFiles embed.FS

// knownFeatures is the curated, explicit list of dashboards this deployment
// exposes. Adding a new AI solution's dashboard means adding its featureName
// here deliberately -- the API does not auto-discover featureName values
// from Cosmos, so stray/test documents (any featureName not listed here)
// never surface on the landing page or get a working /dashboard or
// /metrics/summary response.
var knownFeatures = []string{
	"ai-code-review",
}

func isKnownFeature(name string) bool {
	return slices.Contains(knownFeatures, name)
}

// modelPrices holds USD-per-1M-token rates keyed by the `model` field on each
// event. Cost is computed per-event using the rate for that event's own
// model, so switching models later never requires touching historical
// numbers -- just add a new entry here. A model missing from this table
// simply contributes $0 to cost totals (its tokens still count).
//
// completionTokens already includes reasoningTokens as a billed subset (see
// the Azure OpenAI usage fields) -- it's
// priced once at the output rate, never added on top of reasoningTokens.
//
// cachedTokens (a subset of promptTokens, when a sender reports it, and
// captured in tokenTotals.Cached below for visibility) is NOT priced at a
// discount here -- estimateCostUSD still charges the full promptTokens at
// the standard input rate. Cost totals are therefore a conservative
// (upper-bound) overestimate for any feature with a meaningful cache hit
// rate. Confirm the actual discounted
// rate from Azure OpenAI/Foundry billing docs before adding a
// CachedInputPerMillion field and applying it here -- don't guess a %.
type modelPricing struct {
	InputPerMillion  float64 // $ per 1,000,000 prompt tokens
	OutputPerMillion float64 // $ per 1,000,000 completion tokens (includes reasoning)
}

var modelPrices = map[string]modelPricing{
	"gpt-5.4-mini": {InputPerMillion: 0.75, OutputPerMillion: 4.50},
	"gpt-5-mini":   {InputPerMillion: 0.25, OutputPerMillion: 2.00},
	// Key must equal the deployment name sent as `model` by the ai-code-review
	// stage (the pipeline's `modelName` variable). Rates are the published
	// gpt-5.6-luna list prices -- confirm against Foundry billing.
	"gpt-5.6-luna": {InputPerMillion: 0.20, OutputPerMillion: 1.20},
}

func estimateCostUSD(model string, promptTokens, completionTokens float64) float64 {
	price, ok := modelPrices[model]
	if !ok {
		return 0
	}
	return (promptTokens/1_000_000)*price.InputPerMillion + (completionTokens/1_000_000)*price.OutputPerMillion
}

// Event is the generic envelope every sender uses. Only FeatureName is
// required. Everything specific to a feature -- repository, prId,
// commentsCount, tokensUsed, whatever a future AI feature needs -- goes in
// Custom, which is intentionally untyped so it can evolve without any schema
// migration, table edit, or DCR update.
type Event struct {
	ID             string                 `json:"id"` // Cosmos document id
	EventID        string                 `json:"eventId"`
	Timestamp      string                 `json:"timestamp"`   // event time (RFC3339); server fills in if omitted
	ReceivedAt     string                 `json:"receivedAt"`  // server receipt time, always overwritten server-side
	FeatureName    string                 `json:"featureName"` // required; partition key; e.g. "ai-code-review"
	FeatureVersion string                 `json:"featureVersion,omitempty"`
	Source         string                 `json:"source,omitempty"` // e.g. "ado-pipeline", "github-action", "manual"
	SchemaVersion  string                 `json:"schemaVersion,omitempty"`
	Custom         map[string]interface{} `json:"custom,omitempty"` // fully free-form, feature-specific payload
}

type server struct {
	container *azcosmos.ContainerClient
}

func main() {
	endpoint := requireEnv("COSMOS_ENDPOINT")
	key := requireEnv("COSMOS_KEY")
	dbName := requireEnv("COSMOS_DATABASE")
	containerName := requireEnv("COSMOS_CONTAINER")
	container, err := newContainerClient(endpoint, key, dbName, containerName)
	if err != nil {
		log.Fatal(err)
	}
	handler := newHandler(container)

	port := os.Getenv("PORT")
	if port == "" {
		port = "8080"
	}
	log.Printf("ai-metrics-api listening on :%s", port)
	log.Fatal(http.ListenAndServe(":"+port, handler))
}

func newContainerClient(endpoint, key, dbName, containerName string) (*azcosmos.ContainerClient, error) {
	cred, err := azcosmos.NewKeyCredential(key)
	if err != nil {
		return nil, fmt.Errorf("invalid COSMOS_KEY: %w", err)
	}
	client, err := azcosmos.NewClientWithKey(endpoint, cred, nil)
	if err != nil {
		return nil, fmt.Errorf("failed to create cosmos client: %w", err)
	}
	container, err := client.NewContainer(dbName, containerName)
	if err != nil {
		return nil, fmt.Errorf("failed to get container client: %w", err)
	}
	return container, nil
}

// newHandler wires every route; main and the characterisation tests share it.
func newHandler(container *azcosmos.ContainerClient) http.Handler {
	srv := &server{container: container}

	mux := http.NewServeMux()
	mux.HandleFunc("/healthz", srv.handleHealth)
	mux.HandleFunc("/events", srv.handleEvents)
	mux.HandleFunc("/metrics/summary", srv.handleSummary)
	mux.HandleFunc("/metrics/features", srv.handleFeatures)
	mux.HandleFunc("/dashboard", srv.handleFeatureDashboard)
	mux.HandleFunc("/", srv.handleIndex)
	return withCORS(mux)
}

func requireEnv(name string) string {
	v := os.Getenv(name)
	if v == "" {
		log.Fatalf("missing required environment variable %s", name)
	}
	return v
}

func withCORS(h http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Access-Control-Allow-Origin", "*")
		w.Header().Set("Access-Control-Allow-Headers", "Content-Type, X-Api-Key")
		w.Header().Set("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
		if r.Method == http.MethodOptions {
			w.WriteHeader(http.StatusNoContent)
			return
		}
		h.ServeHTTP(w, r)
	})
}

func (s *server) handleHealth(w http.ResponseWriter, r *http.Request) {
	w.WriteHeader(http.StatusOK)
	w.Write([]byte("ok"))
}

// handleEvents accepts ANY JSON body with at least a "featureName" field.
// Every other field, including anything under "custom", is stored as-is --
// there is no schema to validate against, on purpose. Senders are free to
// add new fields at any time; older documents simply won't have them.
func (s *server) handleEvents(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, `{"error":"method not allowed"}`, http.StatusMethodNotAllowed)
		return
	}
	var e Event
	if err := json.NewDecoder(r.Body).Decode(&e); err != nil {
		http.Error(w, fmt.Sprintf(`{"error":"invalid JSON: %s"}`, err), http.StatusBadRequest)
		return
	}
	if e.FeatureName == "" {
		http.Error(w, `{"error":"featureName is required"}`, http.StatusBadRequest)
		return
	}
	if e.EventID == "" {
		e.EventID = newID()
	}
	e.ID = e.EventID
	if e.Timestamp == "" {
		e.Timestamp = time.Now().UTC().Format(time.RFC3339)
	}
	e.ReceivedAt = time.Now().UTC().Format(time.RFC3339)
	if e.SchemaVersion == "" {
		e.SchemaVersion = "1"
	}

	body, err := json.Marshal(e)
	if err != nil {
		http.Error(w, `{"error":"internal encode error"}`, http.StatusInternalServerError)
		return
	}

	pk := azcosmos.NewPartitionKeyString(e.FeatureName)
	ctx, cancel := context.WithTimeout(r.Context(), 10*time.Second)
	defer cancel()
	// CreateItem (not UpsertItem): eventId is always server-generated and
	// never resent by a well-behaved sender, so a duplicate id indicates a
	// real problem (e.g. a retrying client) worth surfacing distinctly
	// rather than silently overwriting the original event.
	if _, err := s.container.CreateItem(ctx, pk, body, nil); err != nil {
		var respErr *azcore.ResponseError
		if errors.As(err, &respErr) && respErr.StatusCode == http.StatusConflict {
			http.Error(w, `{"error":"duplicate eventId"}`, http.StatusConflict)
			return
		}
		log.Printf("cosmos create failed: %v", err)
		http.Error(w, `{"error":"failed to store event"}`, http.StatusBadGateway)
		return
	}

	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusCreated)
	json.NewEncoder(w).Encode(map[string]string{"eventId": e.EventID})
}

// --- Summary/aggregation -----------------------------------------------
//
// GET /metrics/summary aggregates one feature's events. The aggregation
// (buildCodeReviewSummary) is intentionally a little opinionated -- it assumes
// a "repository", "prId" and "commentsCount" inside custom, matching the AI
// Code Review use case -- while staying generic at the storage layer.

// queryRow is the shape read back from Cosmos --
// every feature's events carry `custom` + `timestamp` regardless of what's
// inside `custom`.
type queryRow struct {
	Custom    map[string]interface{} `json:"custom"`
	Timestamp string                 `json:"timestamp"`
}

// featureRowsQuery feeds the aggregation. ORDER BY timestamp ASC
// so per-day/per-PR/per-session bucketing sees events in chronological
// order (e.g. buildCodeReviewSummary's seenPRs dedup relies on the first
// time a PR is seen also being chronologically first).
const featureRowsQuery = "SELECT c.custom, c.timestamp FROM c WHERE c.featureName = @feature AND c.timestamp >= @since ORDER BY c.timestamp ASC"

func (s *server) newFeatureRowsPager(feature, since string) *runtime.Pager[azcosmos.QueryItemsResponse] {
	pk := azcosmos.NewPartitionKeyString(feature)
	opts := &azcosmos.QueryOptions{
		QueryParameters: []azcosmos.QueryParameter{
			{Name: "@feature", Value: feature},
			{Name: "@since", Value: since},
		},
	}
	return s.container.NewQueryItemsPager(featureRowsQuery, pk, opts)
}

type repoSummary struct {
	Repository        string  `json:"repository"`
	PRsReviewed       int     `json:"prsReviewed"`
	TotalComments     float64 `json:"totalComments"`
	AvgCommentsPerPR  float64 `json:"avgCommentsPerPR"`
	ReviewsWithNoCmts int     `json:"reviewsWithoutComments"`
	ReviewsWithCmts   int     `json:"reviewsWithComments"`
	Errors            int     `json:"errors"`
}

// daySummary is one point on the "PRs reviewed per day" timeline. Every
// calendar day in the window is present, zero-filled, so the chart doesn't
// silently skip quiet days.
type daySummary struct {
	Date        string `json:"date"` // YYYY-MM-DD, UTC
	PRsReviewed int    `json:"prsReviewed"`
}

// dayCost is one point on the "Est. cost per day" timeline, zero-filled like
// daySummary.
type dayCost struct {
	Date       string  `json:"date"`
	EstCostUSD float64 `json:"estCostUsd"`
}

// dayLatency is one point on the "Latency per day" timeline. Days with no
// timed events (all latencyMs missing/zero) come through as zero values.
type dayLatency struct {
	Date  string  `json:"date"`
	P50Ms float64 `json:"p50Ms"`
	P95Ms float64 `json:"p95Ms"`
}

type tokenTotals struct {
	Prompt     float64 `json:"prompt"`
	Cached     float64 `json:"cached"` // subset of Prompt -- see modelPrices comment on why cost isn't discounted for this yet
	Completion float64 `json:"completion"`
	Reasoning  float64 `json:"reasoning"`
	Total      float64 `json:"total"`
}

type severityTotals struct {
	Critical   int `json:"critical"`
	Warning    int `json:"warning"`
	Suggestion int `json:"suggestion"`
	Unknown    int `json:"unknown"`
}

// fileHotspot is one entry in the "files most often commented on" ranking,
// scoped to a single repository -- file paths are repo-relative, so two
// unrelated repos can share a path (e.g. "/src/utils/formatCurrency.ts"),
// and aggregating across repos would silently merge their counts together.
type fileHotspot struct {
	Repository string `json:"repository"`
	File       string `json:"file"`
	Comments   int    `json:"comments"`
}

// repoFileKey is the aggregation key for fileComments -- a struct key (not a
// "repo|file" string) so a "|" inside a file path can never collide with the
// separator.
type repoFileKey struct {
	Repository string
	File       string
}

type errorTypeCount struct {
	ErrorType string `json:"errorType"`
	Count     int    `json:"count"`
}

// modelSummary breaks volume/reliability/cost down by the `model` deployment
// used for the review. latencySum/latencyCount are internal accumulators
// (unexported -> never marshaled) used to compute AvgLatencyMs once the loop
// finishes.
type modelSummary struct {
	Model        string  `json:"model"`
	Runs         int     `json:"runs"`
	Errors       int     `json:"errors"`
	AvgLatencyMs float64 `json:"avgLatencyMs"`
	TotalTokens  float64 `json:"totalTokens"`
	EstCostUSD   float64 `json:"estCostUsd"`
	latencySum   float64
	latencyCount int
}

// engineSummary breaks runs down by the template/engine version that
// produced them (custom.engineVersion), so a rollout can be compared across
// versions. Events from older templates carry no engineVersion and are
// grouped under "(unknown)". Partial counts runs with outcome "partial"
// (some batches failed, the rest were posted).
type engineSummary struct {
	EngineVersion string  `json:"engineVersion"`
	Runs          int     `json:"runs"`
	Errors        int     `json:"errors"`
	Partial       int     `json:"partial"`
	EstCostUSD    float64 `json:"estCostUsd"`
}

type summaryResponse struct {
	FeatureName          string           `json:"featureName"`
	WindowDays           int              `json:"windowDays"`
	TotalEvents          int              `json:"totalEvents"`
	TotalPRsReviewed     int              `json:"totalPRsReviewed"`
	TotalReviewsWithCmts int              `json:"totalReviewsWithComments"`
	TotalReviewsNoCmts   int              `json:"totalReviewsWithoutComments"`
	TotalErrors          int              `json:"totalErrors"`
	TotalPartial         int              `json:"totalPartial"`
	ErrorRate            float64          `json:"errorRate"` // 0..1, errors / totalEvents
	DedupRate            float64          `json:"dedupRate"` // 0..1, commentsSkippedDuplicate / commentsProposed
	TotalTokens          tokenTotals      `json:"totalTokens"`
	TotalEstCostUSD      float64          `json:"totalEstCostUsd"`
	AvgLatencyMs         float64          `json:"avgLatencyMs"`
	P95LatencyMs         float64          `json:"p95LatencyMs"`
	SeverityBreakdown    severityTotals   `json:"severityBreakdown"`
	ByRepository         []repoSummary    `json:"byRepository"`
	ByDay                []daySummary     `json:"byDay"`
	ByDayCost            []dayCost        `json:"byDayCost"`
	ByDayLatency         []dayLatency     `json:"byDayLatency"`
	TopFiles             []fileHotspot    `json:"topFiles"`
	ByErrorType          []errorTypeCount `json:"byErrorType"`
	ByModel              []modelSummary   `json:"byModel"`
	ByEngineVersion      []engineSummary  `json:"byEngineVersion"`
}

func (s *server) handleSummary(w http.ResponseWriter, r *http.Request) {
	feature := r.URL.Query().Get("feature")
	if feature == "" {
		http.Error(w, `{"error":"feature query param is required"}`, http.StatusBadRequest)
		return
	}
	if !isKnownFeature(feature) {
		http.Error(w, `{"error":"unknown feature"}`, http.StatusNotFound)
		return
	}
	days := 30
	if d := r.URL.Query().Get("days"); d != "" {
		if parsed, err := strconv.Atoi(d); err == nil && parsed > 0 {
			days = parsed
		}
	}
	sinceTime := time.Now().UTC().AddDate(0, 0, -days)
	since := sinceTime.Format(time.RFC3339)

	ctx, cancel := context.WithTimeout(r.Context(), 15*time.Second)
	defer cancel()

	resp, err := s.buildCodeReviewSummary(ctx, feature, days, since, sinceTime)
	if err != nil {
		log.Printf("cosmos query failed: %v", err)
		http.Error(w, `{"error":"failed to query metrics"}`, http.StatusBadGateway)
		return
	}

	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(resp)
}

// buildCodeReviewSummary is the AI Code Review aggregation (PR/repo-shaped).
func (s *server) buildCodeReviewSummary(ctx context.Context, feature string, days int, since string, sinceTime time.Time) (*summaryResponse, error) {
	pager := s.newFeatureRowsPager(feature, since)

	byRepo := map[string]*repoSummary{}
	byDay := map[string]int{}
	seenPRs := map[string]bool{}
	totalWith, totalWithout, totalEvents, totalErrors := 0, 0, 0, 0

	var tokens tokenTotals
	var totalCost float64
	var latencies []float64
	byDayLatencies := map[string][]float64{}
	byDayCostMap := map[string]float64{}
	var severity severityTotals
	fileComments := map[repoFileKey]int{}
	errorTypes := map[string]int{}
	modelStats := map[string]*modelSummary{}
	engineStats := map[string]*engineSummary{}
	totalPartial := 0
	var totalCommentsProposed, totalCommentsSkippedDup float64

	for pager.More() {
		page, err := pager.NextPage(ctx)
		if err != nil {
			return nil, err
		}
		for _, itemBytes := range page.Items {
			var it queryRow
			if err := json.Unmarshal(itemBytes, &it); err != nil {
				continue
			}
			totalEvents++
			repository := stringFromAny(it.Custom["repository"])
			outcome := stringFromAny(it.Custom["outcome"])
			model := stringFromAny(it.Custom["model"])
			date := dateFromTimestamp(it.Timestamp)

			// Cost/latency/token accounting applies to every run, successful or
			// not -- a failed LLM call still burns tokens and wall-clock time.
			latencyMs := numberFromAny(it.Custom["latencyMs"])
			promptTokens := numberFromAny(it.Custom["promptTokens"])
			completionTokens := numberFromAny(it.Custom["completionTokens"])
			reasoningTokens := numberFromAny(it.Custom["reasoningTokens"])
			tokensUsed := numberFromAny(it.Custom["tokensUsed"])
			cost := estimateCostUSD(model, promptTokens, completionTokens)

			tokens.Prompt += promptTokens
			tokens.Completion += completionTokens
			tokens.Reasoning += reasoningTokens
			tokens.Total += tokensUsed
			totalCost += cost
			if date != "" {
				byDayCostMap[date] += cost
			}
			if latencyMs > 0 {
				latencies = append(latencies, latencyMs)
				if date != "" {
					byDayLatencies[date] = append(byDayLatencies[date], latencyMs)
				}
			}

			ms, ok := modelStats[model]
			if !ok {
				ms = &modelSummary{Model: model}
				modelStats[model] = ms
			}
			ms.Runs++
			ms.TotalTokens += tokensUsed
			ms.EstCostUSD += cost

			engineVersion := stringFromAny(it.Custom["engineVersion"])
			if engineVersion == "" {
				engineVersion = "(unknown)"
			}
			es, ok := engineStats[engineVersion]
			if !ok {
				es = &engineSummary{EngineVersion: engineVersion}
				engineStats[engineVersion] = es
			}
			es.Runs++
			es.EstCostUSD += cost
			if latencyMs > 0 {
				ms.latencySum += latencyMs
				ms.latencyCount++
			}

			rs, ok := byRepo[repository]
			if !ok {
				rs = &repoSummary{Repository: repository}
				byRepo[repository] = rs
			}

			// A failed run (Tier 4) didn't actually review anything -- comments
			// count is 0 same as a clean "no issues found" run, so without this
			// branch an error would silently count as a successful no-comments
			// review instead of showing up as a failure.
			if outcome == "error" {
				rs.Errors++
				totalErrors++
				ms.Errors++
				es.Errors++
				errType := stringFromAny(it.Custom["errorType"])
				if errType == "" {
					errType = "unknown"
				}
				errorTypes[errType]++
				continue
			}

			// A partial run reviewed some batches and failed others; it still
			// counts as a review below, but is surfaced separately so failed
			// batches are not hidden inside the success numbers.
			if outcome == "partial" {
				totalPartial++
				es.Partial++
			}

			prID := stringFromAny(it.Custom["prId"])
			comments := numberFromAny(it.Custom["commentsCount"])

			prKey := repository + "|" + prID
			if prID != "" && !seenPRs[prKey] {
				seenPRs[prKey] = true
				rs.PRsReviewed++
				if date != "" {
					byDay[date]++
				}
			}
			rs.TotalComments += comments
			if comments > 0 {
				rs.ReviewsWithCmts++
				totalWith++
			} else {
				rs.ReviewsWithNoCmts++
				totalWithout++
			}

			totalCommentsProposed += numberFromAny(it.Custom["commentsProposed"])
			totalCommentsSkippedDup += numberFromAny(it.Custom["commentsSkippedDuplicate"])

			if sevRaw, ok := it.Custom["severityBreakdown"].(map[string]interface{}); ok {
				severity.Critical += int(numberFromAny(sevRaw["critical"]))
				severity.Warning += int(numberFromAny(sevRaw["warning"]))
				severity.Suggestion += int(numberFromAny(sevRaw["suggestion"]))
				severity.Unknown += int(numberFromAny(sevRaw["unknown"]))
			}
			for _, f := range stringSliceFromAny(it.Custom["filesWithComments"]) {
				fileComments[repoFileKey{Repository: repository, File: f}]++
			}
		}
	}

	resp := summaryResponse{
		FeatureName:          feature,
		WindowDays:           days,
		TotalEvents:          totalEvents,
		TotalReviewsWithCmts: totalWith,
		TotalReviewsNoCmts:   totalWithout,
		TotalErrors:          totalErrors,
		TotalPartial:         totalPartial,
		TotalTokens:          tokens,
		TotalEstCostUSD:      totalCost,
		SeverityBreakdown:    severity,
	}
	for _, rs := range byRepo {
		if rs.PRsReviewed > 0 {
			rs.AvgCommentsPerPR = rs.TotalComments / float64(rs.PRsReviewed)
		}
		resp.TotalPRsReviewed += rs.PRsReviewed
		resp.ByRepository = append(resp.ByRepository, *rs)
	}
	rangeFrom := clampRangeStart(sinceTime, minNonEmpty(earliestKey(byDay), earliestKey(byDayCostMap), earliestKey(byDayLatencies)))
	resp.ByDay = buildDayRange(rangeFrom, time.Now().UTC(), byDay)
	resp.ByDayCost = buildDayCostRange(rangeFrom, time.Now().UTC(), byDayCostMap)
	resp.ByDayLatency = buildDayLatencyRange(rangeFrom, time.Now().UTC(), byDayLatencies)

	if totalEvents > 0 {
		resp.ErrorRate = float64(totalErrors) / float64(totalEvents)
	}
	if totalCommentsProposed > 0 {
		resp.DedupRate = totalCommentsSkippedDup / totalCommentsProposed
	}
	if len(latencies) > 0 {
		sort.Float64s(latencies)
		sum := 0.0
		for _, v := range latencies {
			sum += v
		}
		resp.AvgLatencyMs = sum / float64(len(latencies))
		resp.P95LatencyMs = percentile(latencies, 95)
	}

	for key, count := range fileComments {
		resp.TopFiles = append(resp.TopFiles, fileHotspot{Repository: key.Repository, File: key.File, Comments: count})
	}
	sort.Slice(resp.TopFiles, func(i, j int) bool {
		if resp.TopFiles[i].Comments != resp.TopFiles[j].Comments {
			return resp.TopFiles[i].Comments > resp.TopFiles[j].Comments
		}
		if resp.TopFiles[i].Repository != resp.TopFiles[j].Repository {
			return resp.TopFiles[i].Repository < resp.TopFiles[j].Repository
		}
		return resp.TopFiles[i].File < resp.TopFiles[j].File
	})
	if len(resp.TopFiles) > 10 {
		resp.TopFiles = resp.TopFiles[:10]
	}

	for et, count := range errorTypes {
		resp.ByErrorType = append(resp.ByErrorType, errorTypeCount{ErrorType: et, Count: count})
	}
	sort.Slice(resp.ByErrorType, func(i, j int) bool { return resp.ByErrorType[i].Count > resp.ByErrorType[j].Count })

	for _, ms := range modelStats {
		if ms.latencyCount > 0 {
			ms.AvgLatencyMs = ms.latencySum / float64(ms.latencyCount)
		}
		resp.ByModel = append(resp.ByModel, *ms)
	}
	sort.Slice(resp.ByModel, func(i, j int) bool { return resp.ByModel[i].Runs > resp.ByModel[j].Runs })

	for _, es := range engineStats {
		resp.ByEngineVersion = append(resp.ByEngineVersion, *es)
	}
	sort.Slice(resp.ByEngineVersion, func(i, j int) bool {
		if resp.ByEngineVersion[i].Runs != resp.ByEngineVersion[j].Runs {
			return resp.ByEngineVersion[i].Runs > resp.ByEngineVersion[j].Runs
		}
		return resp.ByEngineVersion[i].EngineVersion < resp.ByEngineVersion[j].EngineVersion
	})

	return &resp, nil
}

// boolFromAny is deliberately lenient, same rationale as numberFromAny --
// a "custom" field could arrive as a JSON bool or (rarely) a stringified
// "true"/"false" from a sender that stringifies everything.
func boolFromAny(v interface{}) bool {
	switch t := v.(type) {
	case bool:
		return t
	case string:
		return strings.EqualFold(t, "true")
	}
	return false
}

// handleFeatures lists the known feature dashboards for the landing page.
// This is the static knownFeatures list, not a Cosmos query -- see its
// comment for why: no cross-partition scan, and no risk of test/stray
// documents showing up as their own dashboard.
func (s *server) handleFeatures(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(map[string][]string{"features": knownFeatures})
}

// numberFromAny is deliberately lenient: a "custom" field could arrive as a
// JSON number (decodes to float64), a numeric string (some senders will just
// stringify everything), or be missing entirely. Treat anything unparsable
// as 0 rather than erroring the whole request.
func numberFromAny(v interface{}) float64 {
	switch t := v.(type) {
	case float64:
		return t
	case string:
		f, err := strconv.ParseFloat(t, 64)
		if err == nil {
			return f
		}
	}
	return 0
}

func stringFromAny(v interface{}) string {
	if s, ok := v.(string); ok {
		return s
	}
	if v == nil {
		return ""
	}
	return fmt.Sprintf("%v", v)
}

// stringSliceFromAny reads filesWithComments, which PowerShell's
// ConvertTo-Json collapses from a one-element array down to a bare string
// (a well-known PS quirk) -- accept either shape and always return a slice,
// dropping empty entries.
func stringSliceFromAny(v interface{}) []string {
	switch t := v.(type) {
	case []interface{}:
		out := make([]string, 0, len(t))
		for _, e := range t {
			if s := stringFromAny(e); s != "" {
				out = append(out, s)
			}
		}
		return out
	case string:
		if t == "" {
			return nil
		}
		return []string{t}
	}
	return nil
}

// percentile returns the p-th percentile (0-100) of an ascending-sorted,
// non-empty slice via linear interpolation between the two nearest ranks.
func percentile(sorted []float64, p float64) float64 {
	if len(sorted) == 1 {
		return sorted[0]
	}
	rank := (p / 100) * float64(len(sorted)-1)
	lo := int(rank)
	hi := lo + 1
	if hi >= len(sorted) {
		return sorted[lo]
	}
	frac := rank - float64(lo)
	return sorted[lo] + frac*(sorted[hi]-sorted[lo])
}

// dateFromTimestamp reduces an event's RFC3339 timestamp to its UTC calendar
// date. Returns "" for anything unparsable so callers can skip attribution
// rather than corrupt the day bucket with a bogus key.
func dateFromTimestamp(ts string) string {
	t, err := time.Parse(time.RFC3339, ts)
	if err != nil {
		return ""
	}
	return t.UTC().Format("2006-01-02")
}

// earliestKey returns the smallest map key (day maps are keyed "YYYY-MM-DD",
// so string ordering is chronological), or "" for an empty map.
func earliestKey[V any](m map[string]V) string {
	earliest := ""
	for k := range m {
		if earliest == "" || k < earliest {
			earliest = k
		}
	}
	return earliest
}

// minNonEmpty returns the lexicographically smallest non-empty string.
func minNonEmpty(vals ...string) string {
	min := ""
	for _, v := range vals {
		if v == "" {
			continue
		}
		if min == "" || v < min {
			min = v
		}
	}
	return min
}

// clampRangeStart pulls the zero-fill start forward to the earliest day that
// actually has data, when that's later than `sinceTime`. Without this, an
// "all time" window (days requested far larger than how long the feature has
// existed) would zero-fill years of empty days into every per-day chart.
func clampRangeStart(sinceTime time.Time, earliestDate string) time.Time {
	if earliestDate == "" {
		return sinceTime
	}
	t, err := time.Parse("2006-01-02", earliestDate)
	if err != nil || !t.After(sinceTime) {
		return sinceTime
	}
	return t
}

// buildDayRange zero-fills every calendar day from `from` through `to`
// (inclusive) so the per-day chart shows quiet days as 0 rather than
// skipping them.
func buildDayRange(from, to time.Time, counts map[string]int) []daySummary {
	from = from.Truncate(24 * time.Hour)
	to = to.Truncate(24 * time.Hour)
	out := make([]daySummary, 0, int(to.Sub(from).Hours()/24)+1)
	for d := from; !d.After(to); d = d.AddDate(0, 0, 1) {
		date := d.Format("2006-01-02")
		out = append(out, daySummary{Date: date, PRsReviewed: counts[date]})
	}
	return out
}

// buildDayCostRange zero-fills every calendar day from `from` through `to`
// (inclusive), same rationale as buildDayRange.
func buildDayCostRange(from, to time.Time, costs map[string]float64) []dayCost {
	from = from.Truncate(24 * time.Hour)
	to = to.Truncate(24 * time.Hour)
	out := make([]dayCost, 0, int(to.Sub(from).Hours()/24)+1)
	for d := from; !d.After(to); d = d.AddDate(0, 0, 1) {
		date := d.Format("2006-01-02")
		out = append(out, dayCost{Date: date, EstCostUSD: costs[date]})
	}
	return out
}

// buildDayLatencyRange zero-fills every calendar day from `from` through `to`
// (inclusive); days with no timed events come through as zero p50/p95.
func buildDayLatencyRange(from, to time.Time, byDay map[string][]float64) []dayLatency {
	from = from.Truncate(24 * time.Hour)
	to = to.Truncate(24 * time.Hour)
	out := make([]dayLatency, 0, int(to.Sub(from).Hours()/24)+1)
	for d := from; !d.After(to); d = d.AddDate(0, 0, 1) {
		date := d.Format("2006-01-02")
		dl := dayLatency{Date: date}
		if vals := byDay[date]; len(vals) > 0 {
			sort.Float64s(vals)
			dl.P50Ms = percentile(vals, 50)
			dl.P95Ms = percentile(vals, 95)
		}
		out = append(out, dl)
	}
	return out
}

// handleIndex serves the landing page listing every feature with metrics.
func (s *server) handleIndex(w http.ResponseWriter, r *http.Request) {
	if r.URL.Path != "/" {
		http.NotFound(w, r)
		return
	}
	serveEmbedded(w, "index.html")
}

// handleFeatureDashboard serves the per-feature dashboard shell; the feature
// name itself is read client-side from the ?feature= query param.
func (s *server) handleFeatureDashboard(w http.ResponseWriter, r *http.Request) {
	serveEmbedded(w, "dashboard.html")
}

func serveEmbedded(w http.ResponseWriter, name string) {
	b, err := embeddedFiles.ReadFile(name)
	if err != nil {
		http.Error(w, name+" not found", http.StatusInternalServerError)
		return
	}
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	w.Write(b)
}

func newID() string {
	b := make([]byte, 16)
	_, _ = rand.Read(b)
	b[6] = (b[6] & 0x0f) | 0x40
	b[8] = (b[8] & 0x3f) | 0x80
	return fmt.Sprintf("%x-%x-%x-%x-%x", b[0:4], b[4:6], b[6:8], b[8:10], b[10:16])
}
