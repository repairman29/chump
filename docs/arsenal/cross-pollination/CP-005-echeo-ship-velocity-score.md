# CP-005: Vendor echeo Ship Velocity Score → Chump gap-value scorer

**Target:** Chump skill-aware routing (INFRA-1764) needs a deterministic numeric scorer
**Arsenal match:** `repairman29/echeo` at `src/matchmaker.rs::calculate_ship_velocity_score` (commit `afbe64d6`)
**Recommended route:** Vendoring (port formula to Rust, cite source, substitute embeddings for v0)
**Status:** proposed (2026-05-23, INFRA-1816)

## The Target

INFRA-1764 wants to route a freshly-opened gap to the worker most likely to ship it
fast — the historical-best-performer for the gap's task class. Today the picker is
greedy-FIFO: first eligible worker grabs the first eligible gap. The skill-aware
upgrade needs a numeric **gap-value score** in `0.0..=1.0` per (gap, worker) pair so
the picker (or push-routing daemon FLEET-034) can deterministically choose the best
match instead of the first available.

What's missing today is the **score function itself** — the priority calculus that
takes a `GapRow`, a `WorkerCapabilities`, and a recent-outcomes window and emits a
single float plus human-readable reasons. Without it INFRA-1764 has nothing to call.

echeo already solved this problem for a different surface (matching open-source code
to bounty needs). The formula transfers cleanly.

## The Arsenal Match — Ship Velocity Score formula

### Source (echeo/src/matchmaker.rs, lines 51-106)

The function is a single ~50-line method on `Matchmaker`:

```rust
// echeo/src/matchmaker.rs:53-106 (verbatim)
fn calculate_ship_velocity_score(
    similarity: f32,
    capability: &EmbeddedCapability,
    need: &Need,
) -> (f32, Vec<String>) {
    let mut score = similarity;                          // base: cosine of embeddings
    let mut reasons = Vec::new();

    if similarity > 0.7 {
        reasons.push(format!("High semantic similarity ({:.0}%)", similarity * 100.0));
    } else if similarity > 0.5 {
        reasons.push(format!("Moderate semantic similarity ({:.0}%)", similarity * 100.0));
    }

    // Language boost
    if need.description.to_lowercase()
        .contains(&capability.language.to_lowercase()) {
        score += 0.1;
        reasons.push(format!("Language match: {}", capability.language));
    }

    // Kind boost (function/component/class triplet)
    let need_lower = need.description.to_lowercase();
    let kind_lower = capability.kind.to_lowercase();
    if (kind_lower.contains("function") && need_lower.contains("function"))
        || (kind_lower.contains("component") && need_lower.contains("component"))
        || (kind_lower.contains("class") && need_lower.contains("class")) {
        score += 0.05;
        reasons.push(format!("Type match: {}", capability.kind));
    }

    score = score.min(1.0);                              // clamp
    // existence-of-code reason (line 101-103)
    (score, reasons)
}
```

Threshold gate: `match_need` (line 122) drops candidates with `similarity <= 0.3`
before scoring — sub-threshold matches are not considered at all.

### The `Match` struct (lines 21-27)

```rust
pub struct Match {
    pub need: Need,                  // the bounty / work item
    pub capability: EmbeddedCapability, // the existing primitive (function/component/class)
    pub score: f32,                  // Ship Velocity Score (0.0..=1.0)
    pub reasons: Vec<String>,        // human-readable rationale, ordered by emission
}
```

`reasons` accrues in the order terms fire (similarity → language → kind → existence)
so the audit trail is deterministic and replayable. `capability` carries
`{name, code_snippet, embedding, language, kind, path, line}` (vectorizer.rs lines 29-51).

### Boost rationale

- **Base = cosine similarity** of two 768-dim vectors (Ollama nomic-embed-text) —
  semantic proximity of the need description to the capability code+name+kind blob.
- **+0.1 language match** — Rust capability fits a need that mentions "Rust".
  Larger than +0.05 because language mismatch usually kills shipping outright.
- **+0.05 kind match** — function-shaped need meets a function-shaped primitive.
  Smaller because kind triplet is a soft signal (a "component" might be matched by a
  module with public functions).
- **Clamp at 1.0** — the boosts compose additively but don't punch through the
  semantic ceiling. Without the clamp, three boosts on top of 0.95 similarity
  would emit 1.10 and break downstream sort stability.

## Mapping echeo → Chump

| echeo concept | Chump concept | Translation notes |
|---|---|---|
| `Need` (bounty + description + embedding) | `GapRow` (title, AC, domain, priority, skills_required) | bounty stays optional; embedding deferred to v1 |
| `EmbeddedCapability` (function/component/class with embedding) | `WorkerCapabilities` (skills set, recent ship class, language proficiency) | Capability is per-worker, not per-code-symbol |
| `similarity` (cosine of embeddings) | `base_match` (v0: string-overlap of `skills_required` vs worker `skills`; v1: cosine over learned worker-skill vectors) | identical shape, different distance fn |
| `+0.1` language boost | `+0.10` language boost (Rust gap + Rust worker = +0.10) | identical |
| `+0.05` kind boost | `+0.05` domain boost (INFRA gap + worker with `last_ship_class=INFRA` = +0.05) | identical |
| `min(1.0)` clamp | `min(1.0)` clamp + bottom clamp `max(0.0)` | guard against negative recency penalties |
| `reasons: Vec<String>` | `reasons: Vec<String>` | direct carry-over for observability |
| similarity threshold > 0.3 | unchanged threshold > 0.3 | sub-threshold workers excluded |

**New term Chump adds** that echeo doesn't have: a **recency multiplier**. A worker
who shipped a similar-class gap in the last 24h gets a small bonus (+0.05 if last
ship class matches); a worker whose last ship was a CI failure for a similar class
gets a penalty (−0.05). This consumes `recent_outcomes: &[RoutingOutcome]` and
encodes the "historical-best-performer" intent of INFRA-1764.

## Rust port — `src/gap_scoring.rs`

### Function signature (new module)

```rust
// src/gap_scoring.rs (proposed v0)
pub struct WorkerCapabilities {
    pub session_id: String,
    pub skills: Vec<String>,        // e.g. ["rust", "sqlite", "macos"]
    pub languages: Vec<String>,     // e.g. ["rust", "python"]
    pub last_ship_class: Option<String>, // e.g. "INFRA" | "FLEET" | "DOC"
}

pub struct RoutingOutcome {
    pub gap_class: String,          // domain prefix at routing time
    pub worker_session: String,
    pub shipped_ok: bool,
    pub age_hours: u32,
}

pub fn calculate_gap_value_score(
    gap: &GapRow,
    worker_caps: &WorkerCapabilities,
    recent_outcomes: &[RoutingOutcome],
) -> (f32, Vec<String>) {
    // 1. Base similarity (v0: string-overlap; v1: embedding cosine)
    // 2. Language boost +0.10 if any worker_caps.languages matches gap.skills_required
    // 3. Domain boost +0.05 if gap.domain == worker_caps.last_ship_class
    // 4. Recency multiplier: ±0.05 from recent_outcomes filtered by gap.domain
    // 5. Clamp to 0.0..=1.0; return (score, reasons)
}
```

### v0 vs v1 (the embeddings tradeoff)

**v0 (this gap, INFRA-1816):** substitute Jaccard string-overlap of
`gap.skills_required` against `worker_caps.skills` for echeo's vector cosine. Loses
semantic nuance ("rust" vs "Rust" handled; "async" vs "tokio" not handled), but
zero new infra — no Ollama, no embedding cache, no model dependency. Score remains
in `0.0..=1.0` with the same boost shape. Sufficient to ship INFRA-1764.

**v1 (future, separate gap):** replace base term with cosine over learned worker-skill
embeddings (small model, runs locally — likely `nomic-embed-text` via local LLM
infrastructure already in `project_model_dogfood.md`). The boost terms and clamp
stay identical; only the base distance function changes. Drop-in swap.

The split is deliberate: v0 unblocks INFRA-1764 this sprint without taking on the
embedding-infrastructure dependency. The v1 upgrade slots in behind the same
function signature when the LLM serving layer matures.

## Smoke test spec — `scripts/ci/test-gap-scoring.sh`

Deterministic, no LLM dependency:

```bash
# Inputs (in-test fixture):
#   gap = { domain: "INFRA", priority: "P1", skills_required: ["rust","sqlite"] }
#   worker_caps = { skills: ["rust","sqlite","macos"], languages: ["rust"],
#                   last_ship_class: Some("INFRA") }
#   recent_outcomes = [ {gap_class: "INFRA", shipped_ok: true, age_hours: 2} ]
# Expected score:
#   base (Jaccard: 2/3 overlap of skills) = 0.67
#   + language match (rust) = +0.10
#   + domain match (INFRA) = +0.05
#   + recency (INFRA shipped 2h ago) = +0.05
#   = 0.87, clamped to 1.0 cap (no clamp needed here)
# Assertion: 0.85 <= score <= 0.90 AND reasons contains
#            ["language","domain","recency"]
```

Two adversarial cases:
- **Mismatch:** gap=`DOC`+`python`, worker=`rust`+`INFRA-last-ship` → expect
  `score < 0.3`, no reasons fire.
- **Clamp:** gap+worker match on every term → expect `score == 1.0` exactly,
  all four reasons emitted.

## Observability hook (deferred to picker integration, not this gap)

When the picker (INFRA-1764) calls `calculate_gap_value_score()`, it should
emit `kind=gap_score_computed` to `ambient.jsonl` with
`{gap_id, worker_session, score, reasons[]}`. CP-005 itself stays internal — the
scoring module has no side effects.

## Vendoring lineage (commit body trailer template)

```
Vendored from repairman29/echeo at commit afbe64d6ddea1a89a486015eac1d9584b26d785f
Original: src/matchmaker.rs::calculate_ship_velocity_score (lines 51-106)
Adaptations: (1) base distance fn = string-overlap (v0) instead of cosine,
             (2) added recency term over RoutingOutcome window,
             (3) renamed terms to Chump's gap/worker domain.
```

## Convergence with INFRA-1764

The picker becomes a two-step routine:

1. For each eligible (gap, worker) pair: call `calculate_gap_value_score()`.
2. Sort descending by score; the highest-scoring worker wins the atomic claim CAS.

The existing NATS-KV `try_claim_gap` lease primitive stays unchanged — scoring is a
hint layer above it. If scoring is unavailable (cold start, no outcomes table yet),
the picker falls back to greedy-FIFO. This makes INFRA-1764 a soft-upgrade, not a
breaking change to the picker.

## Lineage / Risk

- **v0 weakness:** string-overlap misses synonymy ("async/tokio", "sql/sqlite"). A
  worker who *can* do the gap but lacks the literal skill string scores low.
  Mitigation: skill-string normalization sweep before computing overlap.
- **Recency gaming:** workers could ship trivial INFRA gaps to inflate their
  INFRA-recency bonus. Mitigation: cap recency contribution at `±0.05` regardless of
  outcome count; the embedding-based v1 will be harder to game.
- **Determinism vs ML:** Ship Velocity is a deterministic formula by design — same
  inputs → same score. Resist the urge to add learned weights until INFRA-1764 has
  shipped and run for two weeks with v0. Premature ML kills auditability.
