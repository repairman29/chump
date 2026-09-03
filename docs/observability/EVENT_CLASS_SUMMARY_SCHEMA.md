# Event Class Summary — Data Model (EFFECTIVE-397 slice, EFFECTIVE-969)

> **Status:** design only. This document defines the schema; it does not ship
> an emitter. It is the contract almanac's `tracemap` organ (or any other
> summarizer of `.chump-locks/ambient.jsonl`) implements against so that
> operational event classes — not just gap-run events — get windowed
> rate/spike/share summaries.
>
> **Motivating gap:** [`EFFECTIVE-397`](../gaps/EFFECTIVE-397.yaml) — tracemap
> reads 0.45% of chump's ambient stream (20 of 4,394 events across 5 runs; 70
> distinct `kind`s exist) because it only groups gap-run events. The top
> unread kinds are exactly the fleet's operational signal: `farmer_auth_dead`
> (769), `farmer_heartbeat` (769), `github_api_call` (561),
> `operator_recall_suppressed` (522), `operator_recall` (247),
> `farmer_drain_guard` (198), `cache_miss` (138),
> `queue_health_check_failed` (133).

## Purpose

Answer, for any `kind` in the ambient stream over a trailing window: *how
often is this firing, is that rate abnormal, and how much of the stream does
it represent?* A single number (raw count) cannot distinguish "769
`farmer_auth_dead` events is a real recurring outage" from "769 is the known
false-positive class documented in INFRA-2031" — the summary needs rate,
spike, and share together to make that call legible without a human re-deriving
it from raw JSONL each time.

## Schema

One `EventClassSummary` row per distinct `event_kind` observed in the window.

| Field | Type | Required | Description |
|---|---|---|---|
| `event_kind` | string | Yes | The literal `kind` value from the ambient event (e.g. `farmer_auth_dead`). Matches `EVENT_REGISTRY.yaml`'s `kind` field 1:1 where the kind is registered; unregistered kinds are still summarized (registration is a separate hygiene concern, not a prerequisite for visibility). |
| `count` | integer | Yes | Raw number of events of this `kind` observed within `window`. Never negative; `0` is a valid value only when a kind is explicitly tracked as "watched, currently silent" — omit rows for kinds with no occurrences instead. |
| `rate_per_minute` | float | Yes | `count / window.duration_minutes`. Normalizes across window sizes so a 5-minute and a 60-minute summary are comparable at a glance. |
| `spike_indicator` | float | Yes | Ratio of this window's `rate_per_minute` to the trailing baseline rate for the same `event_kind` (e.g. mean over the prior N windows of equal size). `1.0` = at baseline, `>1.0` = elevated, `<1.0` = suppressed. A `spike_indicator` of `null`/absent baseline (first time this kind has been seen) MUST be surfaced as such — see Coverage honesty below — never silently defaulted to `1.0`, which would hide a brand-new event class as "normal." |
| `ratio_to_total` | float | Yes | `count / total_events_in_window` across *all* kinds, in `[0.0, 1.0]`. Answers "how much of the stream is this" independent of absolute volume — a low-count kind can still dominate a quiet window. |

### Window

| Field | Type | Required | Description |
|---|---|---|---|
| `window.duration_minutes` | integer | Yes | Length of the summarization window in minutes. **Default: `5`.** Configurable per invocation (e.g. `--window-minutes 60` for an hourly rollup) — the schema does not hardcode a single window size, only a default. |
| `window.start_ts` | RFC3339 string | Yes | Inclusive start of the window. |
| `window.end_ts` | RFC3339 string | Yes | Exclusive end of the window. |

### Coverage honesty (carried over from EFFECTIVE-397's constraint)

| Field | Type | Required | Description |
|---|---|---|---|
| `coverage.events_read` | integer | Yes | Total events the summarizer actually parsed/considered in the window. |
| `coverage.events_total` | integer | Yes | Total events present in the source file for that window (e.g. all lines in `ambient.jsonl` timestamped within `window`), regardless of whether they were summarized. |
| `coverage.share` | float | Yes | `coverage.events_read / coverage.events_total`. Any consumer of this schema MUST surface this figure alongside the summary — per EFFECTIVE-397 AC4, an instrument must never imply a full read when it only interpreted a fraction of the stream. |

## JSON serialization

```json
{
  "window": {
    "duration_minutes": 5,
    "start_ts": "2026-08-07T14:00:00Z",
    "end_ts": "2026-08-07T14:05:00Z"
  },
  "coverage": {
    "events_read": 312,
    "events_total": 312,
    "share": 1.0
  },
  "summaries": [
    {
      "event_kind": "farmer_auth_dead",
      "count": 41,
      "rate_per_minute": 8.2,
      "spike_indicator": 3.4,
      "ratio_to_total": 0.1314
    },
    {
      "event_kind": "farmer_heartbeat",
      "count": 41,
      "rate_per_minute": 8.2,
      "spike_indicator": 1.02,
      "ratio_to_total": 0.1314
    },
    {
      "event_kind": "cache_miss",
      "count": 9,
      "rate_per_minute": 1.8,
      "spike_indicator": null,
      "ratio_to_total": 0.0288
    }
  ]
}
```

Notes on the example:
- `farmer_auth_dead` at `spike_indicator: 3.4` (3.4x baseline) is the shape
  that separates "known false-positive class, ignore" from "real recurring
  outage, page" — a raw count of 41 cannot make that distinction alone.
- `cache_miss`'s `spike_indicator: null` signals no baseline exists yet for
  that kind in this summarizer's history (first observation), which is
  meaningfully different from `1.0` (at baseline) and must round-trip through
  JSON as `null`, not be coerced to a number.

## Non-goals (out of scope for this slice)

- **Implementation.** This is a schema design only; wiring it into
  `tracemap` (or a new organ) is separate follow-up work in
  `repairman29/almanac` (`skills_required: external_repo:repairman29/almanac`
  territory, per EFFECTIVE-397/398/419).
- **Baseline computation method.** How `spike_indicator`'s trailing baseline
  is computed (simple moving average, EWMA, percentile-based) is an
  implementation choice for whoever builds the summarizer; this schema only
  fixes the field's meaning and range.
- **Alerting/thresholds.** This schema reports facts about the window; it
  does not define what `spike_indicator` value should trigger an alert.
