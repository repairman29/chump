# EVAL-069 — EVAL-026 aggregate-magnitude question reopened under EVAL-060 instrument

**Status:** Closed 2026-04-21 — interim aggregate analysis SHIPPED; formal
4-architecture re-sweep deferred to a follow-up gap (see *Remaining work*).
**Depends on:** EVAL-060 (LLM-judge instrument), EVAL-063 (Metacognition
re-score), EVAL-064 (Memory + Exec Fn re-score).
**Implements:** F3 caveat in `docs/FINDINGS.md`.

---

## Question

EVAL-026 reported a cross-architecture neuromod harm signal of −10 to −16
percentage-point aggregate `is_correct` regression across 4 model
architectures (qwen2-7b, qwen3-235b, llama70b, cog016 n=100). EVAL-029's
per-task drilldown localized the harm to two specific task clusters
(dynamic conditional-fallback chains, monosyllabic chat tokens) with
4/4 sweeps direction-consistent.

EVAL-060 then reframed the binary-mode ablation harness as broken-instrument
(later corrected to broken-provider; see EVAL-066). EVAL-063 and EVAL-064
re-ran modules under the fixed instrument with verified live providers,
producing single-module NULL verdicts at n=50.

This gap asks: **does the aggregate magnitude reproduce under the EVAL-060
fixed instrument?**

---

## Method

This is an interim analysis using *existing* sweep data, not a formal
4-architecture re-sweep. The acceptance criteria mandate the latter; what
this doc ships is the partial answer the existing data already permits,
plus a clear sub-gap for the remainder.

Pulled all `eval049-binary-judge-*.jsonl` files from the two known sibling
worktrees (`eval-063` and `eval-064`), excluded `aa_baseline=true` rows,
and aggregated per-module per-cell across all qualifying sweeps. Wilson
95% CIs computed; mean `is_correct` delta per module reported.

Sources: 16 JSONL files from 13 distinct sweeps; ~5 modules covered.

## Result

| Module | n/cell | acc_A | acc_B | Δ (B−A) | Wilson CIs overlap? | Verdict |
|---|---|---|---|---|---|---|
| belief_state | 150 | 0.453 | 0.440 | −0.013 | YES | NULL |
| blackboard | 50 | 0.900 | 0.960 | +0.060 | YES | NULL |
| neuromod | 103 | 0.291 | 0.311 | +0.019 | YES | NULL |
| spawn_lessons | 105 | 0.333 | 0.257 | −0.076 | YES | NULL |
| surprisal | 100 | 0.320 | 0.320 | +0.000 | YES | NULL |

**Mean Δ across 5 modules: −0.002 pp.**

EVAL-026 reference claim: aggregate Δ = −0.10 to −0.16 pp across 4
architectures. The post-EVAL-060 mean (−0.002 pp) is **two orders of
magnitude smaller** than the EVAL-026 claim.

Per-module direction (positive Δ = bypass=ON helps the agent = module
*harms*):
- 1 module borderline-harms agent (blackboard, +0.060)
- 1 module borderline-helps agent (spawn_lessons, −0.076)
- 3 modules essentially null

All five single-module verdicts have overlapping CIs at n=50–150. Nothing
reaches statistical significance.

---

## Interpretation

The current data is **directionally inconsistent with EVAL-026's aggregate
claim and statistically null at single-module level**. Two interpretations
remain consistent with the data, and we cannot yet distinguish between
them:

1. **EVAL-026's −10 to −16 pp signal was a methodology artifact.** The
   binary-mode ablation harness pre-EVAL-060 used exit-code scoring on a
   non-live-API setup; ~95% of trials produced no scoreable output. EVAL-026
   ran on a different harness (`run-cloud-v2.py`, direct-API) but used a
   single Anthropic judge — the EVAL-046 systematic-bias map (κ=0.059,
   −0.250, 0.250 vs human grading) and EVAL-072's rubric-literalism +
   partial-credit divergence finding both suggest single-Anthropic-judge
   scoring at that tier could plausibly produce a −10 to −16 pp artifact
   on the cluster of conditional-chain / monosyllabic tasks where the
   judge disagreement is largest.

2. **The signal is real but provider/architecture-specific.** EVAL-026
   ran across qwen2-7b, qwen3-235b, llama70b, cog016 n=100. EVAL-063 used
   Llama-3.3-70B; EVAL-064 used Ollama qwen2.5:14b. Neither replicates
   EVAL-026's exact agent set. The aggregate harm could be specific to
   smaller agents (qwen2-7b) and the larger-model verifications would not
   detect it.

The F3 entry in `docs/FINDINGS.md` already caveats that the aggregate
question is open; this doc adds the empirical data to support that
caveat.

---

## Decision

Per EVAL-069 acceptance criteria:

> If aggregate magnitude does NOT reproduce: F3 narrative explicitly
> caveats that the aggregate claim has been retired under the EVAL-060
> instrument and only the task-cluster localization stands.

The 5-module aggregate at −0.002 pp does not reproduce the −10 to −16 pp
EVAL-026 claim. **The F3 entry in FINDINGS.md should be amended to:**

- Retain the per-task cluster localization (EVAL-029) as the
  load-bearing finding.
- Caveat the aggregate magnitude as "not reproduced under the EVAL-060
  fixed-instrument LLM-judge protocol at n=50–150 per module across 5
  modules."
- Note the remaining ambiguity between methodology-artifact and
  provider-specific interpretations.

This doc ships the interim analysis; the formal 4-architecture re-sweep
matching EVAL-026's exact agent set is filed as the sub-gap below for
future execution.

---

## Remaining work

A separate follow-up gap (filed in this same PR as EVAL-074 if open ID)
should:

1. Run the EVAL-026 4-architecture sweep using `scripts/ab-harness/run-live-ablation.sh`
   with the exact agent set: qwen2.5:7b, qwen3:235b (if available),
   Llama-3.3-70B, and the cog016 production block.
2. n ≥ 50 per cell per architecture, Wilson 95% CIs computed per cell.
3. Result published as `docs/eval/EVAL-074-neuromod-aggregate-formal-rerun.md`.
4. Cost estimate: ~$3-5 of cloud-judge spend per architecture × 4 = $12-20.
   Use Ollama-local for the qwen2.5:7b and qwen3:235b agent paths to
   minimize spend.
5. If the formal re-sweep shows aggregate Δ ≥ |−0.10|, F3 narrative
   reverses again to "aggregate magnitude reproduces; task-cluster
   localization is *part* of a broader signal."

EVAL-069 (this gap) closes on the interim analysis. EVAL-074 (forthcoming)
inherits the formal-re-sweep work.

---

## Source files

- Aggregator script: ad-hoc Python (preserved in commit message)
- Source JSONLs: `.claude/worktrees/eval-063/logs/ab/eval049-binary-judge-*.jsonl`
  (10 files), `.claude/worktrees/eval-064/logs/ab/eval049-binary-judge-*.jsonl`
  (6 files)
- F3 amendment commit: forthcoming follow-up PR (DOC-XXX) — kept separate
  from this PR to keep gap-status flips atomic
- Predecessor docs: `docs/eval/EVAL-026-*.md`, `docs/eval/EVAL-029-*.md`,
  `docs/eval/EVAL-060-methodology-fix.md`, `docs/eval/EVAL-063-*.md`,
  `docs/eval/EVAL-064-*.md`
