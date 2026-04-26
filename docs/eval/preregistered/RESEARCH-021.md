# Preregistration — RESEARCH-021

> **Status:** LOCKED. See [`README.md`](README.md) for the protocol.

## 1. Gap reference

- **Gap ID:** RESEARCH-021
- **Gap title:** Tier-dependence replication across 4 model families
- **Source critique:** [`docs/research/RESEARCH_CRITIQUE_2026-04-21.md`](../../RESEARCH_CRITIQUE_2026-04-21.md) §4
- **Author:** agent frontier-scientist (Opus 4.7)
- **Preregistration date:** 2026-04-21

## 2. Hypothesis

**H1 (primary).** The tier-dependent lessons-block effect — small-tier
frontier models benefit, large-tier frontier models are harmed — reproduces
in ≥3 of 4 model families. Formally, for each family F:
- `Δ_small_F(A−B) > +0.05` on correctness OR hallucination (beneficial)
- `Δ_large_F(A−B) < −0.05` on correctness OR hallucination (harmful)
- Tier-direction match: `sign(Δ_small) ≠ sign(Δ_large)` with CIs excluding zero in both.

H1 holds if the above is true for ≥3 of the 4 families tested.

**H0.** Tier-direction match holds in <3 families — the effect is
Anthropic-family-specific, not field-wide.

**Alternative explanations:**
- *Family-specific training-data contamination* — not fully controllable,
  flagged as limitation.
- *Judge-family bias favoring same-family agent* — addressed by cross-family
  judge panel (see design).

## 3. Design

### Cells

Per family × tier:
| Cell | Lessons block | Expected |
|---|---|---|
| A | ON (COG-016-versioned block) | small: +Δ; large: −Δ |
| B | OFF | neutral baseline |

### Model matrix

| Family | Small tier (~8B) | Large tier (~70B+) | Provider |
|---|---|---|---|
| Anthropic | claude-haiku-4-5 | claude-sonnet-4-5 | Anthropic API |
| Meta | Llama-3.3-8B-Instruct | Llama-3.3-70B-Instruct-Turbo | Together |
| Alibaba | Qwen-2.5-7B-Instruct | Qwen-2.5-72B-Instruct | Together |
| DeepSeek | DeepSeek-V3-small (activated 37B) | DeepSeek-V3 (671B total / 37B active) | Together / DeepSeek API |

Gemma dropped from the matrix — 4 families is enough for the H1 check and
reduces budget/risk. File follow-up RESEARCH-027 for Gemma if 4-family
replication succeeds.

### Sample size

- **n per cell:** 100
- **Total trials:** 4 families × 2 tiers × 2 cells × 100 = **1,600 trials**

### Judge panel

Per RESEARCH_INTEGRITY.md: cross-family judging required. Use a **3-judge
panel per trial**, one judge from a different family than the agent under
test, majority-vote scoring. Judges:
- claude-sonnet-4-5 (Anthropic)
- Llama-3.3-70B-Instruct-Turbo (Meta)
- Qwen-2.5-72B-Instruct (Alibaba)

Rule: for any trial, exclude the same-family judge. E.g., when testing a
Llama agent, use {Anthropic, Qwen} judges — 2 judges majority (tie-break:
conservative = correctness=0).

### Fixture

`scripts/ab-harness/fixtures/reflection_tasks.json` — same fixture as
EVAL-025 and RESEARCH-018 for compositionality.

## 4. Primary metric

Per (family, tier, cell): mean correctness + hallucination rate across
n=100, with Wilson 95% CIs. Per family: tier-direction match (see H1).

Aggregate: **tier-direction-match count** across 4 families (integer 0–4).

## 5. Secondary metrics

- Per-judge agreement (full panel kappa, pairwise kappa).
- Per-family effect magnitude — comparable with the Anthropic-only Chump
  baseline.
- Hallucination-rate as secondary outcome (F2-compatible).

## 6. Stopping rule

Planned n=100. No early stop. Budget cap: $150.

## 7. Analysis plan

**Primary (preregistered):**
1. Per-family per-tier mean + Wilson 95% CI.
2. Per-family tier-direction match test.
3. Count of families with tier-direction match (0–4).
4. H1 supported iff count ≥3.

**Secondary (preregistered):**
- Cross-family Δ heterogeneity: I² statistic across the 4 families'
  per-tier deltas. High I² means families are not interchangeable; low I²
  means a universal effect.
- Separate analysis for correctness vs hallucination outcome axes.

## 8. Exclusion rules

Standard: empty output, judge HTTP error, endpoint unreachable.
Additionally: if any family's Cell A or Cell B mean = 0 or 1 (floor or
ceiling), that family is reported separately and excluded from the main
count (H1 test ignores ceiling-effect families).

## 9. Decision rule

**If H1 supported (count ≥3):** publish as "field-wide tier-dependent
injection effect." Strongest publishable framing for Paper 1.

**If count = 2:** publish as "effect reproduces in ~half the frontier
families tested." Paper 1 reframes to case-study mode. Discuss per-family
mechanism hypotheses.

**If count ≤1:** finding is Anthropic-family-specific. Paper 1 reframes
to "a case study of tier-dependent injection in one model family" —
still publishable but much narrower scope.

## 10. Budget

- **Cloud:** ~$150 (1,600 trials × ~$0.09 amortized over 4 providers × 3 judges)
- **Wall-clock:** ~24 hours if sweeps parallelize across providers
- **Human time:** ~10 hours (harness family-adapter + analysis + writeup)

## 11. Risks & mitigations

| Risk | Mitigation |
|---|---|
| Together rate-limit on free tier | Ship sweep in 200-trial chunks with backoff; pay for provisioned if necessary ($10 buffer budget). |
| Model contamination (one of the judge models trained on same data as agent) | Flag per family in Limitations. No mitigation possible without closed training data access. |
| Tier-ceiling effect (large model at 1.0 on easy tasks) | Exclusion rule §8 handles it. |
| python3.12 / anthropic foot-gun on non-Anthropic SDKs | Verify each provider SDK pre-sweep in 3-trial smoke. |
| Lessons block format doesn't transfer across model families (e.g. Llama ignores `<system>` blocks) | Pre-sweep inspection: confirm each model's output shows signs of reading the lessons (per RESEARCH-022 reference analysis) before main sweep. |

---

## Deviations

### 2026-04-24 — n=20 pilot stage added before n=100 main sweep

**Change.** Execute the design in two stages instead of a single n=100 sweep:

1. **Pilot (n=20/cell, 320 trials).** Same matrix, same judges, same metrics.
   Budget ~$15–25, wall-clock ~80 min on Together free tier
   (~15 sec/trial measured). Goal: catch operational failures (provider SDK
   foot-guns per Risk #4, lessons-block transfer per Risk #5, ceiling effects
   per §8) **before** spending $150.
2. **Main (n=80/cell additional, 1,280 more trials).** Run iff pilot passes
   gate criteria below. Combined n=100/cell matches the locked design.

**Gate criteria from pilot → main (preregistered now to avoid p-hacking):**
- All 4 families produce non-empty Cell A and Cell B output for both tiers
  (no provider/SDK blockers).
- No family hits §8 ceiling/floor (mean ∈ {0, 1}) on Cell B at n=20 — if it
  does, drop that family from main and document; H1 count denominator drops
  accordingly.
- Lessons block shows evidence of being read by each family (per Risk #5
  pre-sweep inspection): at minimum, the agent's reasoning traces reference
  lessons content in ≥1 of the 20 small-tier Cell A trials.

**What the pilot does NOT do.** It does **not** test H1. n=20/cell Wilson 95%
CIs are too wide (~±0.22 on a 0.5 baseline) to claim tier-direction match.
H1 is tested only on the combined n=100. If the pilot incidentally shows a
strong direction, that does **not** count as evidence — only the prereg'd
n=100 analysis does.

**Why this is honest.** Stages are declared before any data is collected.
Gate criteria are mechanical (no peeking-at-effect-size), so they cannot
inflate Type-I error on H1. The pilot consumes ≤17% of the total budget
and de-risks the rest.

**Harness path.** `scripts/ab-harness/run-cloud-v2.py` invoked once per
(family, tier) — single-model per invocation; outer shell loop iterates
the 8 (family × tier) cells × 2 lessons-versions (`cog016` vs `none`).
Cross-family judge panel via `--judge` CSV with same-family exclusion
applied per-family in the loop.

---

## Result document

`docs/eval/RESEARCH-021-tier-dependence-4-family.md` after sweep.
