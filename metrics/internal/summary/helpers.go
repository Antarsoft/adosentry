package summary

import (
	"fmt"
	"sort"
	"strconv"
	"time"
)

// numberFromAny is deliberately lenient: a "custom" field could arrive as a
// JSON number (decodes to float64), a numeric string (some senders will just
// stringify everything), or be missing entirely. Treat anything unparsable
// as 0 rather than erroring the whole request.
func numberFromAny(v any) float64 {
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

func stringFromAny(v any) string {
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
func stringSliceFromAny(v any) []string {
	switch t := v.(type) {
	case []any:
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
