package summary

import (
	"math"
	"slices"
	"testing"
	"time"

	"github.com/antarsoft/adosentry/metrics/internal/pricing"
	"github.com/antarsoft/adosentry/metrics/internal/storage"
)

var now = time.Date(2026, 3, 10, 15, 0, 0, 0, time.UTC)

func ts(daysAgo, hour int) string {
	day := now.Truncate(24*time.Hour).AddDate(0, 0, -daysAgo)
	return day.Add(time.Duration(hour) * time.Hour).Format(time.RFC3339)
}

func row(timestamp string, custom map[string]any) storage.Row {
	return storage.Row{Timestamp: timestamp, Custom: custom}
}

func run(t *testing.T, days int, rows ...storage.Row) *Response {
	t.Helper()
	prices, err := pricing.Parse([]byte(`{"models":{
		"model-a":{"inputPerMillion":1,"outputPerMillion":10},
		"model-b":{"inputPerMillion":2,"outputPerMillion":20}}}`))
	if err != nil {
		t.Fatal(err)
	}
	agg := New("ai-code-review", days, now.AddDate(0, 0, -days), prices)
	for _, r := range rows {
		agg.Add(r)
	}
	return agg.Result(now)
}

func near(a, b float64) bool { return math.Abs(a-b) < 1e-9 }

func repo(resp *Response, name string) repoSummary {
	for _, r := range resp.ByRepository {
		if r.Repository == name {
			return r
		}
	}
	return repoSummary{}
}

func TestAggregation(t *testing.T) {
	tests := []struct {
		name  string
		rows  []storage.Row
		check func(t *testing.T, r *Response)
	}{
		{
			name: "no events",
			check: func(t *testing.T, r *Response) {
				if r.TotalEvents != 0 || r.ErrorRate != 0 || r.DedupRate != 0 || r.AvgLatencyMs != 0 || r.TotalEstCostUSD != 0 {
					t.Errorf("non-zero totals: %+v", r)
				}
				if r.ByRepository != nil || r.TopFiles != nil || r.ByModel != nil {
					t.Error("lists should stay nil (null in JSON) with no events")
				}
			},
		},
		{
			name: "a review with comments",
			rows: []storage.Row{row(ts(1, 9), map[string]any{"repository": "r", "prId": "1", "commentsCount": 4.0})},
			check: func(t *testing.T, r *Response) {
				got := repo(r, "r")
				if got.PRsReviewed != 1 || got.TotalComments != 4 || got.AvgCommentsPerPR != 4 || got.ReviewsWithCmts != 1 || got.ReviewsWithNoCmts != 0 {
					t.Errorf("repo = %+v", got)
				}
				if r.TotalPRsReviewed != 1 || r.TotalReviewsWithCmts != 1 || r.TotalReviewsNoCmts != 0 {
					t.Errorf("totals = %d/%d/%d", r.TotalPRsReviewed, r.TotalReviewsWithCmts, r.TotalReviewsNoCmts)
				}
			},
		},
		{
			name: "a clean review counts as a review without comments",
			rows: []storage.Row{row(ts(1, 9), map[string]any{"repository": "r", "prId": "1"})},
			check: func(t *testing.T, r *Response) {
				if r.TotalReviewsNoCmts != 1 || r.TotalReviewsWithCmts != 0 || r.TotalPRsReviewed != 1 {
					t.Errorf("totals = %+v", r)
				}
			},
		},
		{
			name: "the same PR reviewed twice counts once, on its first day",
			rows: []storage.Row{
				row(ts(3, 9), map[string]any{"repository": "r", "prId": "1", "commentsCount": 2.0}),
				row(ts(1, 9), map[string]any{"repository": "r", "prId": "1", "commentsCount": 1.0}),
			},
			check: func(t *testing.T, r *Response) {
				got := repo(r, "r")
				if got.PRsReviewed != 1 || got.TotalComments != 3 || got.AvgCommentsPerPR != 3 || got.ReviewsWithCmts != 2 {
					t.Errorf("repo = %+v", got)
				}
				want := []int{1, 0, 0, 0} // D-3 .. today
				for i, d := range r.ByDay {
					if d.PRsReviewed != want[i] {
						t.Errorf("byDay = %+v", r.ByDay)
						break
					}
				}
			},
		},
		{
			name: "the same PR id in two repositories is two PRs",
			rows: []storage.Row{
				row(ts(1, 9), map[string]any{"repository": "a", "prId": "1"}),
				row(ts(1, 10), map[string]any{"repository": "b", "prId": "1"}),
			},
			check: func(t *testing.T, r *Response) {
				if r.TotalPRsReviewed != 2 || len(r.ByRepository) != 2 {
					t.Errorf("PRs = %d, repos = %d", r.TotalPRsReviewed, len(r.ByRepository))
				}
			},
		},
		{
			name: "a review without a PR id is a review but not a PR",
			rows: []storage.Row{row(ts(1, 9), map[string]any{"repository": "r", "commentsCount": 1.0})},
			check: func(t *testing.T, r *Response) {
				got := repo(r, "r")
				if got.PRsReviewed != 0 || got.ReviewsWithCmts != 1 || got.AvgCommentsPerPR != 0 {
					t.Errorf("repo = %+v", got)
				}
			},
		},
		{
			name: "an error is not a review, but its tokens, cost and latency count",
			rows: []storage.Row{row(ts(1, 9), map[string]any{
				"repository": "r", "prId": "1", "outcome": "error", "errorType": "timeout", "model": "model-a",
				"commentsCount": 5.0, "promptTokens": 1e6, "tokensUsed": 1e6, "latencyMs": 900.0,
			})},
			check: func(t *testing.T, r *Response) {
				got := repo(r, "r")
				if got.Errors != 1 || got.PRsReviewed != 0 || got.TotalComments != 0 || r.TotalReviewsNoCmts != 0 {
					t.Errorf("repo = %+v", got)
				}
				if r.TotalErrors != 1 || r.ErrorRate != 1 || !near(r.TotalEstCostUSD, 1) || r.AvgLatencyMs != 900 || r.TotalTokens.Total != 1e6 {
					t.Errorf("totals = %+v", r)
				}
				if !slices.Equal(r.ByErrorType, []errorTypeCount{{"timeout", 1}}) {
					t.Errorf("byErrorType = %+v", r.ByErrorType)
				}
				if r.ByModel[0].Errors != 1 || r.ByEngineVersion[0].Errors != 1 {
					t.Errorf("model/engine errors not counted: %+v %+v", r.ByModel, r.ByEngineVersion)
				}
			},
		},
		{
			name: "an error without a type is filed as unknown",
			rows: []storage.Row{row(ts(1, 9), map[string]any{"outcome": "error"})},
			check: func(t *testing.T, r *Response) {
				if !slices.Equal(r.ByErrorType, []errorTypeCount{{"unknown", 1}}) {
					t.Errorf("byErrorType = %+v", r.ByErrorType)
				}
			},
		},
		{
			name: "a partial run is a review and is counted as partial",
			rows: []storage.Row{row(ts(1, 9), map[string]any{"repository": "r", "prId": "1", "outcome": "partial", "engineVersion": "2.0.0", "commentsCount": 1.0})},
			check: func(t *testing.T, r *Response) {
				if r.TotalPartial != 1 || r.TotalPRsReviewed != 1 || r.TotalErrors != 0 {
					t.Errorf("totals = %+v", r)
				}
				if r.ByEngineVersion[0] != (engineSummary{EngineVersion: "2.0.0", Runs: 1, Partial: 1}) {
					t.Errorf("engine = %+v", r.ByEngineVersion)
				}
			},
		},
		{
			name: "numbers sent as strings are read; junk is zero",
			rows: []storage.Row{row(ts(1, 9), map[string]any{
				"repository": "r", "prId": 7.0, "commentsCount": "3", "promptTokens": "1000000", "model": "model-b",
				"latencyMs": "not a number", "tokensUsed": true,
			})},
			check: func(t *testing.T, r *Response) {
				if repo(r, "r").TotalComments != 3 || repo(r, "r").PRsReviewed != 1 {
					t.Errorf("repo = %+v", repo(r, "r"))
				}
				if !near(r.TotalEstCostUSD, 2) || r.AvgLatencyMs != 0 || r.TotalTokens.Total != 0 {
					t.Errorf("cost %v, latency %v, tokens %v", r.TotalEstCostUSD, r.AvgLatencyMs, r.TotalTokens.Total)
				}
			},
		},
		{
			name: "severity counts add up across runs",
			rows: []storage.Row{
				row(ts(1, 9), map[string]any{"severityBreakdown": map[string]any{"critical": 1.0, "warning": "2"}}),
				row(ts(1, 10), map[string]any{"severityBreakdown": map[string]any{"critical": 1.0, "suggestion": 3.0, "unknown": 4.0}}),
				row(ts(1, 11), map[string]any{"severityBreakdown": "not an object"}),
			},
			check: func(t *testing.T, r *Response) {
				if r.SeverityBreakdown != (severityTotals{Critical: 2, Warning: 2, Suggestion: 3, Unknown: 4}) {
					t.Errorf("severity = %+v", r.SeverityBreakdown)
				}
			},
		},
		{
			name: "dedup rate is skipped duplicates over proposed comments",
			rows: []storage.Row{
				row(ts(1, 9), map[string]any{"commentsProposed": 6.0, "commentsSkippedDuplicate": 1.0}),
				row(ts(1, 10), map[string]any{"commentsProposed": 2.0, "commentsSkippedDuplicate": 1.0}),
				row(ts(1, 11), map[string]any{"outcome": "error", "commentsProposed": 100.0, "commentsSkippedDuplicate": 100.0}),
			},
			check: func(t *testing.T, r *Response) {
				if !near(r.DedupRate, 0.25) {
					t.Errorf("dedupRate = %v, want 0.25 (errors excluded)", r.DedupRate)
				}
			},
		},
		{
			name: "files: array or bare string, empty names dropped, ranked per repository",
			rows: []storage.Row{
				row(ts(1, 9), map[string]any{"repository": "a", "filesWithComments": []any{"/x.go", "", "/y.go"}}),
				row(ts(1, 10), map[string]any{"repository": "a", "filesWithComments": "/x.go"}),
				row(ts(1, 11), map[string]any{"repository": "b", "filesWithComments": []any{"/x.go"}}),
				row(ts(1, 12), map[string]any{"repository": "b", "filesWithComments": ""}),
			},
			check: func(t *testing.T, r *Response) {
				want := []fileHotspot{{"a", "/x.go", 2}, {"a", "/y.go", 1}, {"b", "/x.go", 1}}
				if !slices.Equal(r.TopFiles, want) {
					t.Errorf("topFiles = %+v, want %+v", r.TopFiles, want)
				}
			},
		},
		{
			name: "only the top ten files are kept",
			rows: func() []storage.Row {
				files := []any{}
				for _, f := range []string{"/k", "/j", "/i", "/h", "/g", "/f", "/e", "/d", "/c", "/b", "/a"} {
					files = append(files, f)
				}
				return []storage.Row{
					row(ts(1, 9), map[string]any{"repository": "r", "filesWithComments": files}),
					row(ts(1, 10), map[string]any{"repository": "r", "filesWithComments": "/z"}),
					row(ts(1, 11), map[string]any{"repository": "r", "filesWithComments": "/z"}),
				}
			}(),
			check: func(t *testing.T, r *Response) {
				if len(r.TopFiles) != 10 || r.TopFiles[0] != (fileHotspot{"r", "/z", 2}) || r.TopFiles[9].File != "/i" {
					t.Errorf("topFiles = %+v", r.TopFiles)
				}
			},
		},
		{
			name: "latency: average and p95 ignore missing and zero values",
			rows: []storage.Row{
				row(ts(1, 9), map[string]any{"latencyMs": 100.0}),
				row(ts(1, 10), map[string]any{"latencyMs": 300.0}),
				row(ts(1, 11), map[string]any{"latencyMs": 0.0}),
				row(ts(1, 12), map[string]any{}),
			},
			check: func(t *testing.T, r *Response) {
				if r.AvgLatencyMs != 200 || !near(r.P95LatencyMs, 290) {
					t.Errorf("avg %v, p95 %v", r.AvgLatencyMs, r.P95LatencyMs)
				}
				day := r.ByDayLatency[len(r.ByDayLatency)-2]
				if day.P50Ms != 200 || !near(day.P95Ms, 290) {
					t.Errorf("yesterday's latency = %+v", day)
				}
			},
		},
		{
			name: "cost and tokens by model; an unknown model costs nothing",
			rows: []storage.Row{
				row(ts(2, 9), map[string]any{"model": "model-a", "promptTokens": 500_000.0, "completionTokens": 100_000.0, "reasoningTokens": 40_000.0, "tokensUsed": 600_000.0, "latencyMs": 10.0}),
				row(ts(1, 9), map[string]any{"model": "model-a", "promptTokens": 500_000.0, "tokensUsed": 500_000.0, "latencyMs": 30.0}),
				row(ts(1, 10), map[string]any{"model": "model-unpriced", "promptTokens": 9e6, "completionTokens": 9e6, "tokensUsed": 18e6}),
			},
			check: func(t *testing.T, r *Response) {
				// model-a: 1M prompt * $1 + 0.1M completion * $10 = $2.
				if !near(r.TotalEstCostUSD, 2) {
					t.Errorf("total cost = %v, want 2", r.TotalEstCostUSD)
				}
				if r.TotalTokens != (tokenTotals{Prompt: 10e6, Completion: 9.1e6, Reasoning: 40_000, Total: 19.1e6}) {
					t.Errorf("tokens = %+v", r.TotalTokens)
				}
				a, unpriced := r.ByModel[0], r.ByModel[1]
				if a.Model != "model-a" || a.Runs != 2 || !near(a.EstCostUSD, 2) || a.AvgLatencyMs != 20 || a.TotalTokens != 1.1e6 {
					t.Errorf("model-a = %+v", a)
				}
				if unpriced.Model != "model-unpriced" || unpriced.EstCostUSD != 0 || unpriced.TotalTokens != 18e6 {
					t.Errorf("unpriced = %+v", unpriced)
				}
				costs := []float64{}
				for _, d := range r.ByDayCost {
					costs = append(costs, d.EstCostUSD)
				}
				if len(costs) != 3 || !near(costs[0], 1.5) || !near(costs[1], 0.5) || costs[2] != 0 {
					t.Errorf("byDayCost = %v", costs)
				}
			},
		},
		{
			name: "events without engineVersion are grouped as (unknown); ties sort by name",
			rows: []storage.Row{
				row(ts(1, 9), map[string]any{"engineVersion": "1.1.0"}),
				row(ts(1, 10), map[string]any{}),
				row(ts(1, 11), map[string]any{"engineVersion": "1.0.0"}),
				row(ts(1, 12), map[string]any{"engineVersion": "1.1.0"}),
			},
			check: func(t *testing.T, r *Response) {
				var got []string
				for _, e := range r.ByEngineVersion {
					got = append(got, e.EngineVersion)
				}
				if !slices.Equal(got, []string{"1.1.0", "(unknown)", "1.0.0"}) {
					t.Errorf("engines = %v", got)
				}
			},
		},
		{
			name: "an unparsable timestamp counts everywhere except the day charts",
			rows: []storage.Row{row("yesterday", map[string]any{"repository": "r", "prId": "1", "latencyMs": 50.0, "model": "model-a", "promptTokens": 1e6})},
			check: func(t *testing.T, r *Response) {
				if r.TotalPRsReviewed != 1 || r.AvgLatencyMs != 50 || !near(r.TotalEstCostUSD, 1) {
					t.Errorf("totals = %+v", r)
				}
				for _, d := range r.ByDay {
					if d.PRsReviewed != 0 {
						t.Errorf("byDay has a PR: %+v", r.ByDay)
					}
				}
				if len(r.ByDay) != 8 {
					t.Errorf("byDay has %d days, want the full 7-day window plus today", len(r.ByDay))
				}
			},
		},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			tt.check(t, run(t, 7, tt.rows...))
		})
	}
}

func TestDayRanges(t *testing.T) {
	tests := []struct {
		name      string
		days      int
		rows      []storage.Row
		wantFirst string
		wantLen   int
	}{
		{"empty window is zero-filled from the window start", 3, nil, "2026-03-07", 4},
		{"range starts at the first day with data", 30, []storage.Row{row(ts(2, 1), map[string]any{"prId": "1"})}, "2026-03-08", 3},
		{"cost-only data also sets the start", 30, []storage.Row{row(ts(4, 1), map[string]any{"outcome": "error"})}, "2026-03-06", 5},
		{"data before the window start does not extend it", 2, []storage.Row{row(ts(5, 1), map[string]any{"prId": "1"})}, "2026-03-08", 3},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			r := run(t, tt.days, tt.rows...)
			for name, dates := range map[string][]string{
				"byDay":        dates(r.ByDay, func(d daySummary) string { return d.Date }),
				"byDayCost":    dates(r.ByDayCost, func(d dayCost) string { return d.Date }),
				"byDayLatency": dates(r.ByDayLatency, func(d dayLatency) string { return d.Date }),
			} {
				if len(dates) != tt.wantLen || dates[0] != tt.wantFirst || dates[len(dates)-1] != "2026-03-10" {
					t.Errorf("%s = %v, want %d days from %s to 2026-03-10", name, dates, tt.wantLen, tt.wantFirst)
				}
			}
		})
	}
}

func dates[T any](list []T, date func(T) string) []string {
	out := make([]string, len(list))
	for i, v := range list {
		out[i] = date(v)
	}
	return out
}

func TestPercentile(t *testing.T) {
	tests := []struct {
		vals []float64
		p    float64
		want float64
	}{
		{[]float64{42}, 95, 42},
		{[]float64{10, 20}, 50, 15},
		{[]float64{10, 20, 30, 40}, 95, 38.5},
		{[]float64{10, 20, 30, 40}, 100, 40},
		{[]float64{10, 20, 30, 40}, 0, 10},
	}
	for _, tt := range tests {
		if got := percentile(tt.vals, tt.p); !near(got, tt.want) {
			t.Errorf("percentile(%v, %v) = %v, want %v", tt.vals, tt.p, got, tt.want)
		}
	}
}

func TestLenientReaders(t *testing.T) {
	numbers := []struct {
		in   any
		want float64
	}{
		{3.5, 3.5}, {"12", 12}, {"1e3", 1000}, {"", 0}, {"abc", 0}, {nil, 0}, {true, 0}, {map[string]any{}, 0},
	}
	for _, tt := range numbers {
		if got := numberFromAny(tt.in); got != tt.want {
			t.Errorf("numberFromAny(%#v) = %v, want %v", tt.in, got, tt.want)
		}
	}
	strs := []struct {
		in   any
		want string
	}{
		{"x", "x"}, {nil, ""}, {7.0, "7"}, {1234567.0, "1.234567e+06"}, {true, "true"},
	}
	for _, tt := range strs {
		if got := stringFromAny(tt.in); got != tt.want {
			t.Errorf("stringFromAny(%#v) = %q, want %q", tt.in, got, tt.want)
		}
	}
	slicesIn := []struct {
		in   any
		want []string
	}{
		{[]any{"a", "", 3.0}, []string{"a", "3"}}, {"a", []string{"a"}}, {"", nil}, {nil, nil}, {4.0, nil},
	}
	for _, tt := range slicesIn {
		if got := stringSliceFromAny(tt.in); !slices.Equal(got, tt.want) {
			t.Errorf("stringSliceFromAny(%#v) = %v, want %v", tt.in, got, tt.want)
		}
	}
}
