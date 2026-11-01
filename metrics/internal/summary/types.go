package summary

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
	Cached     float64 `json:"cached"` // subset of Prompt -- see the pricing package on why cost isn't discounted for this yet
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
	// Comments counts reviews (runs) that commented on the file, not individual
	// comments: events carry filesWithComments, a per-run list of paths. The JSON
	// name is kept for compatibility.
	Comments int `json:"comments"`
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

// Response is the body of GET /metrics/summary.
type Response struct {
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
