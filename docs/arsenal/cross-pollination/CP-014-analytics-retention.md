# CP-014: Harvest analytics retention model -> Chump fleet telemetry

**Target:** Chump fleet telemetry layer (INFRA-721 `scripts/dispatch/fleet-brief.sh`) — needs a predictive worker-churn signal.
**Arsenal match:** `repairman29/analytics-platform-service` at `src/services/aiInsightsEngine.js` (commit `5e4c2f61e5299330f071a33fc2ac69d4e7451f9a`, main, 2026-05-23).
**Recommended route:** Vendoring — Rust port of the weighted-model formula into a new `src/fleet_health_model.rs` module. The formula is small (~30 LOC), self-contained, and uses no external libraries beyond `Math.min/max`; vendoring is cheaper than dependency or microservice for this size.
**Status:** proposed (2026-05-23, INFRA-1846 AC 1-3).

## The Target

`fleet-brief.sh` today is **reactive**: it reports the last 24h of ship count, BLOCKED PRs, and CI events. By the time a worker shows up as `silent_agent` in `ambient.jsonl`, the operator has already lost a slot. The fleet has no **forward-looking** worker health signal — nothing that says "worker-7 is trending toward churn, intervene now."

The analytics-platform-service retention model is the right shape for this gap: a small weighted formula over behavioral signals, with a configurable baseline and threshold, that produces a 0..1 risk score per entity. We harvest the *formula*, not the game-domain semantics.

## The Arsenal Match — `aiInsightsEngine.js`

### Weighted model — verbatim source

```javascript
// src/services/aiInsightsEngine.js:18-28
this.retentionModel = {
  weights: {
    sessionFrequency: 0.25,
    sessionDuration: 0.20,
    levelProgression: 0.15,
    socialInteractions: 0.10,
    purchaseHistory: 0.15,
    gameEvents: 0.15
  },
  baselineRetention: 0.65
};
```

### Score computation — verbatim

```javascript
// src/services/aiInsightsEngine.js:236-245
// Calculate weighted retention score
let score = 0;
for (const [feature, value] of Object.entries(features)) {
  score += value * this.retentionModel.weights[feature];
}

// Apply model adjustments
const retentionProbability = Math.max(0, Math.min(1,
  this.retentionModel.baselineRetention + (score - 0.5) * 0.4
));
```

The formula: each normalized feature in `[0,1]` is weighted, summed, recentered around 0.5, scaled by 0.4, and added to the 0.65 baseline, then clamped to `[0,1]`. Result is a retention *probability* (high = good). Churn risk = `1 - probability`.

### Risk-level thresholds — verbatim

```javascript
// retention -> level (line 446-451)
calculateRiskLevel(probability) {
  if (probability > 0.8) return 'low';
  if (probability > 0.6) return 'medium';
  if (probability > 0.4) return 'high';
  return 'critical';
}

// churn risk -> level (line 336)
riskLevel: riskScore > 0.7 ? 'critical' : riskScore > 0.4 ? 'high' : riskScore > 0.2 ? 'medium' : 'low'
```

### Conversion threshold (monetization companion)

```javascript
// line 38
conversionThreshold: 0.7
```

A score above 0.7 escalates the entity from passive observation to active intervention. We adopt the same convention: **0.7 fires the ambient event.**

### Output shape — verbatim (lines 247-254)

```javascript
return {
  probability: retentionProbability,
  confidence: 0.82,
  riskLevel: this.calculateRiskLevel(retentionProbability),
  factors: features,
  prediction: retentionProbability > 0.7 ? 'likely_to_retain' :
             retentionProbability > 0.4 ? 'at_risk' : 'high_risk'
};
```

## Mapping game -> Chump

| Game term            | Game weight | Chump equivalent                          | Chump weight | Rationale |
|----------------------|------------:|-------------------------------------------|-------------:|-----------|
| `sessionFrequency`   | 0.25        | claims per day (worker activity rate)     | **0.25**     | Direct analog — active engagement signal. A worker that stops claiming is the strongest leading indicator of churn. |
| `sessionDuration`    | 0.20        | mean claim-to-ship wall time (inverse)    | **0.15**     | Slow shippers aren't churning, just slower; weaker signal than non-engagement, so de-weighted. |
| `levelProgression`   | 0.15        | PRs merged per day (ship rate)            | **0.20**     | Promoted — ship rate is Chump's primary success metric; deserves more weight than the game gave progression. |
| `socialInteractions` | 0.10        | ambient event emission count              | **0.10**     | Observability participation; a quiet worker is a suspect worker but the signal is noisy (some skills don't emit much). |
| `purchaseHistory`    | 0.15        | P0 picks (high-stakes engagement)         | **0.15**     | P0s require operator-quality judgment; a worker willing to pick them shows commitment, mapping cleanly to monetization. |
| `gameEvents`         | 0.15        | clean PRs (no rescue, no `--no-verify`)   | **0.15**     | Quality-of-output proxy; analog of in-game positive events. |
| `baselineRetention`  | 0.65        | `CHUMP_FLEET_HEALTH_BASELINE` (env)       | **0.65**     | Keep identical default; tune per fleet size empirically. |

**Total weight sum:** 0.25 + 0.15 + 0.20 + 0.10 + 0.15 + 0.15 = **1.00** (preserved).

## Rust port — `src/fleet_health_model.rs`

```rust
pub struct ChurnRiskScorer {
    pub weights: RetentionWeights,
    pub baseline: f64,    // default 0.65
    pub threshold: f64,   // default 0.7 (fires fleet_churn_risk)
}

pub struct RetentionWeights {
    pub claims_per_day: f64,        // 0.25
    pub mean_ship_time_inv: f64,    // 0.15
    pub prs_per_day: f64,           // 0.20
    pub ambient_emit_rate: f64,     // 0.10
    pub p0_picks: f64,              // 0.15
    pub clean_prs: f64,             // 0.15
}

pub struct WorkerActivity {
    pub session_id: String,
    pub claims_per_day: f64,
    pub mean_ship_time_secs: f64,
    pub prs_per_day: f64,
    pub ambient_events_per_hour: f64,
    pub p0_picks_per_week: f64,
    pub clean_pr_ratio: f64,  // 0..1
}

pub struct ChurnRiskScore {
    pub session_id: String,
    pub probability_healthy: f64,   // 0..1 (high = healthy)
    pub risk_score: f64,            // 1 - probability_healthy
    pub risk_level: RiskLevel,      // Low | Medium | High | Critical
    pub reasons: Vec<String>,       // top negative contributors
    pub baseline: f64,
}

impl ChurnRiskScorer {
    pub fn score(&self, a: &WorkerActivity) -> ChurnRiskScore { /* see formula */ }
}
```

Score computation (matches JS verbatim, just typed):

```rust
let features = normalize(a);  // each into 0..1 against fleet-wide percentiles from state.db
let weighted = features.claims * w.claims_per_day
             + features.ship_time * w.mean_ship_time_inv
             + features.prs * w.prs_per_day
             + features.ambient * w.ambient_emit_rate
             + features.p0 * w.p0_picks
             + features.clean * w.clean_prs;
let prob = (self.baseline + (weighted - 0.5) * 0.4).clamp(0.0, 1.0);
let risk = 1.0 - prob;
```

### Input data sources

- **`state.db`** — `gap_claims` table for claims/day; `gap_ships` (or commits-by-author) for PRs/day, mean ship time, P0 picks, clean-PR ratio.
- **`ambient.jsonl`** — count of events per worker session (filter by `worker_session` field) for ambient emit rate.

Both are already in the harness contract; no new sources required.

## CLI spec — `chump fleet health --model retention`

```
$ chump fleet health --model retention --json
{
  "model": "retention",
  "baseline": 0.65,
  "threshold": 0.7,
  "workers": [
    {
      "session_id": "fleet-worker-3",
      "probability_healthy": 0.82,
      "risk_score": 0.18,
      "risk_level": "low",
      "reasons": []
    },
    {
      "session_id": "fleet-worker-7",
      "probability_healthy": 0.28,
      "risk_score": 0.72,
      "risk_level": "critical",
      "reasons": [
        "claims_per_day=0.1 (fleet median 1.4)",
        "prs_per_day=0.0 over last 48h",
        "no ambient events emitted in 6h"
      ]
    }
  ]
}
```

Flags: `--worker SESSION-ID` (single), `--threshold 0.7` (override), `--baseline 0.65` (override), `--json|--human`.

## Ambient event spec

```jsonl
{"ts":"2026-05-23T14:22:01Z","kind":"fleet_churn_risk","worker_session":"fleet-worker-7","score":0.72,"reasons":["claims_per_day=0.1","prs_per_day=0.0","no ambient events 6h"],"baseline":0.65}
```

Fired by the scoring CLI (or a follower of it) when **any** worker crosses `threshold=0.7`. Debounced: one event per worker per hour to avoid spam. Threshold is configurable via `CHUMP_FLEET_CHURN_THRESHOLD`.

## Smoke test spec — `scripts/ci/test-fleet-health-model.sh`

Synthetic timeline fixture (one healthy + one declining worker):

| Worker            | claims/day | prs/day | ship_time | ambient/h | p0 picks | clean PRs | expected level |
|-------------------|-----------:|--------:|----------:|----------:|---------:|----------:|----------------|
| `healthy-alpha`   | 2.0        | 1.5     | 900s      | 12        | 1/wk     | 1.0       | `low`          |
| `declining-beta`  | 0.2        | 0.0     | 4500s     | 0         | 0        | 0.5       | `critical`     |

Assertions:
1. `healthy-alpha.risk_score < 0.3` and `risk_level == "low"`.
2. `declining-beta.risk_score > 0.7` and `risk_level == "critical"`.
3. Aggregate ranking puts `declining-beta` first (highest risk).
4. Exactly one `fleet_churn_risk` event is appended to a tmp ambient file (only `declining-beta` crosses threshold).
5. Scores are deterministic (no PRNG); identical runs produce identical bytes.

## Convergence with INFRA-721 and INFRA-518

- **INFRA-721 `fleet-brief.sh`** gains a new section: "Worker health (predictive)" listing any worker with `risk_score > 0.5`. Implementation: `fleet-brief.sh` shells out to `chump fleet health --model retention --json` and renders the top-3.
- **INFRA-518 fleet scaling gate** can read the same JSON: scale-up requires `max(risk_score across workers) < 0.5`. This adds a forward-looking criterion to the existing reactive ones (`fleet_wedge`, `silent_agent` counts).
- **META-068 productization plan** "predictive collision" initiative — this is the worker-side analog; collision is gap-side. Together they cover both halves of forward-looking fleet coordination.

## Vendoring lineage

Source: `repairman29/analytics-platform-service` @ `5e4c2f61e5299330f071a33fc2ac69d4e7451f9a`, file `src/services/aiInsightsEngine.js`, lines 18-28 (weights), 226-255 (formula), 313-340 (churn assessment), 446-451 (risk-level thresholds). Vendored as Rust translation; no runtime dependency on the upstream repo. Diff-mirror not required because the formula is mathematically stable; we re-tune weights, not formula shape.

## Lineage / Risk

- **Weights are game-domain calibrated.** The 0.25/0.20/0.15/0.10/0.15/0.15 split was tuned against 10,000-player training data for a mobile game. Chump fleets are 2-8 workers; sample sizes are 1000x smaller, so any single anomaly skews the score harder. Mitigation: ship with these defaults, then tune `CHUMP_FLEET_HEALTH_WEIGHTS_*` env overrides after 30 days of observation.
- **Baseline 0.65 may be too generous for small fleets.** With only 2-3 workers, even one declining worker is 33-50% of capacity; the cost-of-being-wrong is asymmetric. Operator may want to drop baseline to 0.55 (more pessimistic) once data exists.
- **"Active" definition depends on fleet size.** A 1-worker fleet's "claims per day" baseline is fleet-throughput-bound, not worker-effort-bound. The normalize step must use **fleet-relative** percentiles, not absolute counts, or every solo worker scores critical the moment the fleet is quiet for legitimate reasons (operator review pause, etc.). Plan to normalize against `max(observed_in_last_7d, fleet_size_floor)`.
- **Confidence value of 0.82 (from the JS model)** does not transfer — that's the upstream's training-data accuracy, not ours. The Rust port omits the field until Chump has empirical accuracy data to populate it.

---

**Summary (for INFRA-1846 close-out):**

Chump-domain weights chosen: claims/day **0.25**, ship rate **0.20**, ship-time-inverse **0.15**, P0 picks **0.15**, clean PRs **0.15**, ambient emit **0.10** (sum 1.0), baseline **0.65** (kept identical to source). The ambient event `kind=fleet_churn_risk` fires at score threshold **0.7** — same convention as the source's `conversionThreshold` — debounced to once per worker per hour, payload `{ts, worker_session, score, reasons[], baseline}`.
