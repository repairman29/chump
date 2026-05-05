# Preregistration — `EVAL-098`

> **Status:** LOCKED at commit `<SHA-filled-at-commit-time>`. Do not edit
> locked fields after data collection begins — add a Deviations entry instead.

## 1. Gap reference

- **Gap ID:** `EVAL-098`
- **Gap title:** validate COG-041 semantic retrieval — for N closed gaps run briefing both ways, measure Jaccard overlap of returned lessons; baseline before flipping CHUMP_LESSONS_SEMANTIC=1 by default
- **Source critique:** COG-041 (#1112) shipped a TF-IDF semantic retrieval path as an alternative to recency×frequency ranking for `chump_improvement_targets`. Default OFF until validated. This eval is the validation step.
- **Author:** chump-Chump-1776471708
- **Preregistration date:** 2026-05-05

## 2. Hypothesis

**Primary hypothesis (H1):**
> If we replace recency × frequency lesson ranking with TF-IDF cosine similarity to the gap text, the lesson sets returned for at least 50% of closed gaps will be MEANINGFULLY DIFFERENT (Jaccard overlap < 0.6) from the recency-frequency baseline.

This is a **divergence** check, not a quality check. We're testing whether the new path actually changes behavior — not yet whether the change is *better*. Better requires either downstream metrics (gap-ship rate after each lesson set) or human grading; both are out of scope for EVAL-098 and would belong to a follow-up EVAL.

**Null hypothesis (H0):**
> The two ranking modes return near-identical sets for the typical gap (mean Jaccard ≥ 0.85, fewer than 30% of gaps with Jaccard < 0.6).
>
> Under H0, semantic retrieval is doing nothing meaningful and the default-off gating should stay.

**Alternative explanations to rule out:**
- *Tokenizer too restrictive* — semantic returns near-empty sets, falling back to recency-frequency. Addressed by reporting per-gap "semantic returned ≥1 lesson" rate; if that's < 80%, H1 acceptance is suspect.
- *Identical ranking by coincidence* — if all 5 lessons are repeated across modes for most gaps because the corpus is narrow, mean Jaccard would be high without semantic mode being broken. Addressed by reporting absolute Jaccard distribution, not just mean.

## 3. Design

### Cells
| Cell | Intervention | Expected direction |
|---|---|---|
| A | `CHUMP_LESSONS_SEMANTIC=0` (recency × frequency, current default) | baseline |
| B | `CHUMP_LESSONS_SEMANTIC=1` (TF-IDF cosine, COG-041) | divergence — Jaccard < 0.6 on ≥ 50% of gaps |

### Sample size
- **n:** 20 closed gaps drawn from `chump gap list --status done`
  - Stratify: 10 INFRA-* + 5 COG-* + 5 EVAL/RESEARCH-*. If a stratum is short, fall back to total-domain pool.
- **Power analysis (informal):** with n=20 and a binary "Jaccard < 0.6" outcome, the 95% CI on a 50% rate is roughly ±22pp. We aren't trying to estimate the rate precisely — we're checking whether the rate clears 50%. n=20 is enough to distinguish 0% from 50% from 100%; finer estimates would need n≥48.
- **Fixtures:** real closed gaps from this repo's `.chump/state.db`. Frozen by gap-id list at run time.

### Model & provider matrix
- **Agent under test:** N/A — this is a pure-Rust ranking comparison. No LLM in the loop. Cross-judge requirement from RESEARCH_INTEGRITY.md doesn't apply because the metric is mechanical (Jaccard over string sets).
- **`single_judge_waived: true`** with reason: "no judge — mechanical Jaccard comparison; no human or LLM grading."

### Randomization & order
- Gap order: deterministic by ID.
- For each gap, run mode A first then mode B (no interleaving needed; modes are pure-deterministic given the same DB snapshot, so order doesn't matter).
- DB snapshot: take a single `.chump/state.db` at start of run, pass via `CHUMP_REPO=<snapshot>` to both invocations so both see the same lesson pool.

## 4. Metrics

### Primary
- **`fraction_meaningfully_different`** = # gaps with Jaccard(A_lessons, B_lessons) < 0.6 / 20
- **Decision rule:** H1 accepted iff `fraction_meaningfully_different ≥ 0.50`.

### Secondary (reported, not load-bearing on H1)
- **Mean Jaccard** across all 20.
- **Median Jaccard.**
- **Per-gap detail table:** gap_id, |A∩B|, |A∪B|, Jaccard, B-only-lessons (preview top 1), A-only-lessons (preview top 1).
- **Empty-rate:** fraction of gaps where mode B returned 0 lessons (semantic fallback to A).

### Pre-registered exclusions
- Gaps whose YAML title is shorter than 20 chars (insufficient query signal).
- Gaps closed in the last 24h (the lesson harvester may not have processed them yet).

## 5. Procedure

```bash
scripts/eval/cog-041-semantic-vs-recency.sh        # produces docs/eval/COG-041-semantic-vs-recency-<date>.md
```

The script:
1. Selects the 20 gap IDs per the stratification rule, prints them at the top of the report.
2. For each gap:
   - Runs `chump --briefing <ID>` with `CHUMP_LESSONS_SEMANTIC=0`, captures lesson-block contents.
   - Runs again with `CHUMP_LESSONS_SEMANTIC=1`.
   - Parses the "Top relevant reflections" section into a Set<String> of lesson directives.
   - Computes Jaccard.
3. Aggregates and writes the markdown report.

## 6. Prohibited claims

This eval CANNOT claim:
- "Semantic ranking is BETTER" — no quality metric measured.
- "Default should flip to ON" — needs a follow-up downstream eval (e.g. ship-rate-by-lesson-set), not just divergence.

What this eval CAN claim:
- "Semantic mode does / does not produce meaningfully different rankings on this corpus."
- "Empty-rate ⇒ tokenizer is appropriately tuned (or not)."
- "Whether to prioritize the follow-up downstream eval at all."

## 7. Single-judge waiver

`single_judge_waived: true` — no judge involved; mechanical Jaccard set comparison only.

## 8. Deviations

(none yet)
