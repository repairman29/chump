# Preregistration — `EVAL-099`

> **Status:** LOCKED at commit `<SHA-filled-at-commit-time>`. Do not edit
> locked fields after data collection begins — add a Deviations entry instead.

## 1. Gap reference

- **Gap ID:** `EVAL-099`
- **Gap title:** COG-041 downstream quality eval — using COG-043 action-telemetry, compare semantic vs recency-frequency by 'lesson-applied rate' over next N sessions
- **Source critique:** EVAL-098 measured DIVERGENCE only ("are the rankings different?"). It explicitly cannot answer "is semantic BETTER?". This eval is the follow-up that makes the BETTER claim — using COG-043's `lessons_shown` / `lesson_applied` / `lesson_not_applied` event stream as the ground-truth signal.
- **Author:** chump-Chump-1776471708
- **Preregistration date:** 2026-05-05

## 2. Hypothesis

**Primary hypothesis (H1):**
> Semantic-mode lesson rankings have a strictly higher mean **lesson-applied rate** than recency-frequency rankings, by at least Δ = +10pp absolute, across ≥ 30 paired briefing→ship cycles.

**Null hypothesis (H0):**
> Semantic-mode applied-rate is within ±10pp of recency-mode applied-rate (no meaningful quality difference) — OR semantic-mode is materially WORSE (-10pp or more).
>
> Under H0, COG-041's default-OFF gating stays. We don't flip the default just because rankings diverge (EVAL-098); we flip only when divergence yields measurable downstream improvement.

**Alternative explanations to rule out:**
- *Selection bias* — the gaps that happen to receive `CHUMP_LESSONS_SEMANTIC=1` differ in difficulty from baseline gaps. Addressed by stratifying on `gap.priority × gap.effort` when computing the rate.
- *Keyword-overlap artifact* — the COG-043 keyword-match grader naturally favors directives whose tokens overlap with the gap's domain text. Semantic mode also selects on that overlap. Risk: we're measuring "did the matcher's keywords appear in the PR" twice. Mitigation: report both raw applied-rate AND a control metric — # of *distinct lesson tokens* that appear in the PR — to detect circular signal.
- *Low n* — telemetry just landed; the corpus will be small for weeks. Decision rule explicit: defer the verdict (NEITHER reject nor accept) until n ≥ 30 paired cycles.

## 3. Design

### Cells
| Cell | Intervention | Source of data |
|---|---|---|
| A | `mode == "recency"` (operator did not set `CHUMP_LESSONS_SEMANTIC=1`) | `lessons_shown` events with `mode: "recency"` and matching `lesson_applied` / `lesson_not_applied` for same gap+session |
| B | `mode == "semantic"` (operator set `CHUMP_LESSONS_SEMANTIC=1`) | same, with `mode: "semantic"` |
| C (excluded) | `mode == "recency_fallback_from_semantic"` (semantic returned 0 hits, fell back) | reported separately as a fallback-rate diagnostic; not folded into A or B |

### Sample size
- **Minimum n per cell:** 30 paired briefing→ship cycles (a "cycle" = exactly one `lessons_shown` event paired with one or more `lesson_applied` / `lesson_not_applied` events for the same `(gap_id, session_id)`).
- **Pairing rule:** the most recent `lessons_shown` for `(gap_id, session_id)` is paired with all subsequent grade events within 7 days for that gap. Older `lessons_shown` events for the same pair are dropped.
- **Power:** at n=30 per cell on a binary outcome with baseline rate 0.5, we can detect Δ ≥ +20pp at α=0.05 with ~0.80 power. The +10pp threshold is conservative — H1 acceptance requires a clear effect, not a marginal one.

### Model & provider matrix
- **Agent under test:** N/A — this is post-hoc analysis of telemetry events emitted by real ship cycles. No new LLM calls.
- **`single_judge_waived: true`** with reason: "the keyword-match grader from COG-043 IS the judge; it's deterministic and identical across cells. The interesting question is whether semantic ranking surfaces directives that align with what gets shipped, not whether the judge agrees with itself."

### Randomization
- Not applicable — observational. Operators choose the mode per-session via env var.
- **Audit:** verify that mode assignment is not correlated with gap difficulty. Report: mean `effort.numeric` (xs=0, s=1, m=2, l=3, xl=4) per cell. If imbalance > 0.5 effort points, flag selection bias as a confounder.

## 4. Metrics

### Primary
- **`applied_rate_A`** = sum(applied events in A) / (sum(applied) + sum(not_applied)) in cell A
- **`applied_rate_B`** = same for cell B
- **`delta_pp`** = `applied_rate_B - applied_rate_A` (in percentage points)
- **Decision rule:** H1 accepted iff `n_A >= 30 AND n_B >= 30 AND delta_pp >= +10`.
  H0 accepted iff `n_A >= 30 AND n_B >= 30 AND delta_pp < +10`.
  Otherwise: `INSUFFICIENT_DATA` (no verdict; re-run later).

### Secondary (reported, not load-bearing on H1)
- **Per-mode mean effort**, to flag selection bias.
- **Mode-C (semantic-fallback) rate** — fraction of semantic invocations that fell back. If > 0.50, semantic mode is mostly NOT semantic in practice; investigate corpus / IDF.
- **Distinct-token-overlap** as the circular-signal control: report the median # of distinct directive tokens that appear in the PR text per cell. If A and B are identical on this control, the keyword-match advantage in B is suspicious.
- **Per-(gap-domain × mode) breakdown** for n ≥ 30 within each domain.

### Pre-registered exclusions
- Briefings where `directives` was empty (no lesson available).
- PRs that bot-merge skipped grading (CHUMP_LESSON_GRADE=0 set, or chump-doctor wedge).
- Cycles where `lessons_shown` ts > 7 days before any grade event (stale pairing).

## 5. Procedure

```bash
scripts/eval/cog-041-quality-vs-recency.sh    # writes docs/eval/COG-041-quality-vs-recency-<date>.md
```

The script:
1. Reads `.chump-locks/ambient.jsonl` + rotated archives.
2. Builds index of `lessons_shown` events by `(gap_id, session_id)`.
3. Builds index of `lesson_applied` / `lesson_not_applied` by same key.
4. Pairs them; computes per-mode applied-rate, delta_pp, fallback rate, mean effort, distinct-token control.
5. Applies the decision rule, writes the verdict.

## 6. Prohibited claims

This eval CANNOT claim:
- "Semantic ranking is provably best." — only "better than recency-frequency by ≥ 10pp on this corpus, on this matcher."
- "Default should flip" without operator review. The verdict surfaces the recommendation; the actual flip is a separate config change Jeff approves.
- Any quality result before n_A ≥ 30 AND n_B ≥ 30. The decision rule explicitly returns INSUFFICIENT_DATA below that, and the harness must respect it.

## 7. Single-judge waiver

`single_judge_waived: true` — the COG-043 keyword-match grader IS the judge, applied uniformly across cells. The interesting question is *which ranking surfaces directives that align with shipped work*, not whether two judges agree.

## 8. Deviations

(none yet)
