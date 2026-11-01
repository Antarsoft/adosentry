// Package summary aggregates one feature's events into the response of
// GET /metrics/summary.
//
// The aggregation is shaped around AI Code Review: it expects "repository",
// "prId" and "commentsCount" inside custom, while storage stays generic. It
// is pure: rows go in through Add, the clock and the price table are passed
// in, and nothing here talks to Cosmos or HTTP.
package summary

import (
	"sort"
	"time"

	"github.com/antarsoft/pullpicket/metrics/internal/pricing"
	"github.com/antarsoft/pullpicket/metrics/internal/storage"
)

// topFilesLimit caps the "files most often commented on" ranking.
const topFilesLimit = 10

// Aggregator accumulates rows. Feed it rows oldest first: a PR counts on the
// day it is first seen.
type Aggregator struct {
	feature   string
	days      int
	sinceTime time.Time
	prices    pricing.Table

	byRepo                  map[string]*repoSummary
	byDay                   map[string]int
	seenPRs                 map[string]bool
	totalWith, totalWithout int
	totalEvents             int
	totalErrors             int
	totalPartial            int
	tokens                  tokenTotals
	totalCost               float64
	latencies               []float64
	byDayLatencies          map[string][]float64
	byDayCost               map[string]float64
	severity                severityTotals
	fileComments            map[repoFileKey]int
	errorTypes              map[string]int
	modelStats              map[string]*modelSummary
	engineStats             map[string]*engineSummary
	commentsProposed        float64
	commentsSkippedDup      float64
}

// New starts an aggregation over the window that begins at sinceTime and
// spans days days.
func New(feature string, days int, sinceTime time.Time, prices pricing.Table) *Aggregator {
	return &Aggregator{
		feature:        feature,
		days:           days,
		sinceTime:      sinceTime,
		prices:         prices,
		byRepo:         map[string]*repoSummary{},
		byDay:          map[string]int{},
		seenPRs:        map[string]bool{},
		byDayLatencies: map[string][]float64{},
		byDayCost:      map[string]float64{},
		fileComments:   map[repoFileKey]int{},
		errorTypes:     map[string]int{},
		modelStats:     map[string]*modelSummary{},
		engineStats:    map[string]*engineSummary{},
	}
}

// Add folds one event into the totals.
func (a *Aggregator) Add(row storage.Row) {
	a.totalEvents++
	custom := row.Custom
	repository := stringFromAny(custom["repository"])
	outcome := stringFromAny(custom["outcome"])
	model := stringFromAny(custom["model"])
	date := dateFromTimestamp(row.Timestamp)

	// Cost, latency and tokens apply to every run, successful or not: a
	// failed LLM call still burns tokens and wall-clock time.
	latencyMs := numberFromAny(custom["latencyMs"])
	promptTokens := numberFromAny(custom["promptTokens"])
	completionTokens := numberFromAny(custom["completionTokens"])
	reasoningTokens := numberFromAny(custom["reasoningTokens"])
	cachedTokens := numberFromAny(custom["cachedTokens"])
	tokensUsed := numberFromAny(custom["tokensUsed"])
	cost := a.prices.EstimateUSD(model, promptTokens, completionTokens)

	a.tokens.Prompt += promptTokens
	a.tokens.Completion += completionTokens
	a.tokens.Reasoning += reasoningTokens
	a.tokens.Cached += cachedTokens
	a.tokens.Total += tokensUsed
	a.totalCost += cost
	if date != "" {
		a.byDayCost[date] += cost
	}
	if latencyMs > 0 {
		a.latencies = append(a.latencies, latencyMs)
		if date != "" {
			a.byDayLatencies[date] = append(a.byDayLatencies[date], latencyMs)
		}
	}

	ms, ok := a.modelStats[model]
	if !ok {
		ms = &modelSummary{Model: model}
		a.modelStats[model] = ms
	}
	ms.Runs++
	ms.TotalTokens += tokensUsed
	ms.EstCostUSD += cost
	if latencyMs > 0 {
		ms.latencySum += latencyMs
		ms.latencyCount++
	}

	engineVersion := stringFromAny(custom["engineVersion"])
	if engineVersion == "" {
		engineVersion = "(unknown)"
	}
	es, ok := a.engineStats[engineVersion]
	if !ok {
		es = &engineSummary{EngineVersion: engineVersion}
		a.engineStats[engineVersion] = es
	}
	es.Runs++
	es.EstCostUSD += cost

	rs, ok := a.byRepo[repository]
	if !ok {
		rs = &repoSummary{Repository: repository}
		a.byRepo[repository] = rs
	}

	// A failed run reviewed nothing. Its comment count is 0 like a clean
	// "no issues found" run, so without this branch an error would count as
	// a successful review with no comments instead of a failure.
	if outcome == "error" {
		rs.Errors++
		a.totalErrors++
		ms.Errors++
		es.Errors++
		errType := stringFromAny(custom["errorType"])
		if errType == "" {
			errType = "unknown"
		}
		a.errorTypes[errType]++
		return
	}

	// A partial run reviewed some batches and failed others. It still counts
	// as a review, but is reported separately so failed batches are not
	// hidden inside the success numbers.
	if outcome == "partial" {
		a.totalPartial++
		es.Partial++
	}

	prID := stringFromAny(custom["prId"])
	comments := numberFromAny(custom["commentsCount"])

	prKey := repository + "|" + prID
	if prID != "" && !a.seenPRs[prKey] {
		a.seenPRs[prKey] = true
		rs.PRsReviewed++
		if date != "" {
			a.byDay[date]++
		}
	}
	rs.TotalComments += comments
	if comments > 0 {
		rs.ReviewsWithCmts++
		a.totalWith++
	} else {
		rs.ReviewsWithNoCmts++
		a.totalWithout++
	}

	a.commentsProposed += numberFromAny(custom["commentsProposed"])
	a.commentsSkippedDup += numberFromAny(custom["commentsSkippedDuplicate"])

	if sev, ok := custom["severityBreakdown"].(map[string]any); ok {
		a.severity.Critical += int(numberFromAny(sev["critical"]))
		a.severity.Warning += int(numberFromAny(sev["warning"]))
		a.severity.Suggestion += int(numberFromAny(sev["suggestion"]))
		a.severity.Unknown += int(numberFromAny(sev["unknown"]))
	}
	for _, f := range stringSliceFromAny(custom["filesWithComments"]) {
		a.fileComments[repoFileKey{Repository: repository, File: f}]++
	}
}

// Result builds the response. now ends the zero-filled day ranges.
func (a *Aggregator) Result(now time.Time) *Response {
	resp := Response{
		FeatureName:          a.feature,
		WindowDays:           a.days,
		TotalEvents:          a.totalEvents,
		TotalReviewsWithCmts: a.totalWith,
		TotalReviewsNoCmts:   a.totalWithout,
		TotalErrors:          a.totalErrors,
		TotalPartial:         a.totalPartial,
		TotalTokens:          a.tokens,
		TotalEstCostUSD:      a.totalCost,
		SeverityBreakdown:    a.severity,
	}
	for _, rs := range a.byRepo {
		if rs.PRsReviewed > 0 {
			rs.AvgCommentsPerPR = rs.TotalComments / float64(rs.PRsReviewed)
		}
		resp.TotalPRsReviewed += rs.PRsReviewed
		resp.ByRepository = append(resp.ByRepository, *rs)
	}
	now = now.UTC()
	rangeFrom := clampRangeStart(a.sinceTime, minNonEmpty(earliestKey(a.byDay), earliestKey(a.byDayCost), earliestKey(a.byDayLatencies)))
	resp.ByDay = buildDayRange(rangeFrom, now, a.byDay)
	resp.ByDayCost = buildDayCostRange(rangeFrom, now, a.byDayCost)
	resp.ByDayLatency = buildDayLatencyRange(rangeFrom, now, a.byDayLatencies)

	if a.totalEvents > 0 {
		resp.ErrorRate = float64(a.totalErrors) / float64(a.totalEvents)
	}
	if a.commentsProposed > 0 {
		resp.DedupRate = a.commentsSkippedDup / a.commentsProposed
	}
	if len(a.latencies) > 0 {
		latencies := append([]float64(nil), a.latencies...)
		sort.Float64s(latencies)
		sum := 0.0
		for _, v := range latencies {
			sum += v
		}
		resp.AvgLatencyMs = sum / float64(len(latencies))
		resp.P95LatencyMs = percentile(latencies, 95)
	}

	for key, count := range a.fileComments {
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
	if len(resp.TopFiles) > topFilesLimit {
		resp.TopFiles = resp.TopFiles[:topFilesLimit]
	}

	for et, count := range a.errorTypes {
		resp.ByErrorType = append(resp.ByErrorType, errorTypeCount{ErrorType: et, Count: count})
	}
	sort.Slice(resp.ByErrorType, func(i, j int) bool { return resp.ByErrorType[i].Count > resp.ByErrorType[j].Count })

	for _, ms := range a.modelStats {
		if ms.latencyCount > 0 {
			ms.AvgLatencyMs = ms.latencySum / float64(ms.latencyCount)
		}
		resp.ByModel = append(resp.ByModel, *ms)
	}
	sort.Slice(resp.ByModel, func(i, j int) bool { return resp.ByModel[i].Runs > resp.ByModel[j].Runs })

	for _, es := range a.engineStats {
		resp.ByEngineVersion = append(resp.ByEngineVersion, *es)
	}
	sort.Slice(resp.ByEngineVersion, func(i, j int) bool {
		if resp.ByEngineVersion[i].Runs != resp.ByEngineVersion[j].Runs {
			return resp.ByEngineVersion[i].Runs > resp.ByEngineVersion[j].Runs
		}
		return resp.ByEngineVersion[i].EngineVersion < resp.ByEngineVersion[j].EngineVersion
	})

	return &resp
}
