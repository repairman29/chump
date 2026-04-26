# Preregistration — RESEARCH-023

> **Status:** LOCKED. Analysis-method specification for causal mediation
> applied to A/B harness data. Post-hoc on existing data + prospective on
> future sweeps.

## 1. Gap reference

- **Gap ID:** RESEARCH-023
- **Gap title:** Counterfactual mediation analysis — upgrade module-contribution claims from average-treatment to natural-direct-effect
- **Source critique:** [`docs/research/RESEARCH_CRITIQUE_2026-04-21.md`](../../RESEARCH_CRITIQUE_2026-04-21.md) §6
- **Author:** agent frontier-scientist (Opus 4.7)
- **Preregistration date:** 2026-04-21

## 2. Hypothesis

This gap is methodology upgrade rather than hypothesis test. The primary
"hypothesis" is that Chump's current aggregate ATE (average treatment
effect) framing inflates causal claims that wouldn't survive a proper
mediation decomposition.

**Analysis-form H1.** For module M, NDE(M) — the natural direct effect —
is measurably smaller than ATE(M) in ≥1 previously-reported finding.
Specifically: `|NDE(M)| < |ATE(M)| by at least 0.03` on the tier-dependent
injection finding.

If true, the published delta is inflated by mediator variables (task-type
distribution, judge-family distribution, etc.) that are not controlled in
the simple ATE estimate.

## 3. Design

Mediation analysis per Pearl (2001) *Direct and Indirect Effects* and
VanderWeele (2015) *Explanation in Causal Inference*.

### Variables
- **Exposure X:** module ON/OFF (treatment)
- **Mediator M:** depending on the finding, one of —
  - `task_type` (reflection vs perception vs neuromod subclass)
  - `judge_family` (Anthropic vs non-Anthropic)
  - `agent_output_length` (bucketed)
- **Outcome Y:** binary correctness (or hallucination, per finding)
- **Covariates C:** model tier, trial SHA (for reproducibility tracking)

### Estimands
- **Total effect (TE):** E[Y|X=1] − E[Y|X=0] — same as current Chump ATE.
- **Natural direct effect (NDE):** E[Y_{X=1,M=M_{X=0}}] − E[Y_{X=0}] —
  the direct causal path from exposure to outcome, fixing the mediator
  at its control-distribution value.
- **Natural indirect effect (NIE):** TE − NDE — mediated path contribution.

### Estimation method

Non-parametric bootstrap (10,000 resamples) on matched cells. For each
bootstrap sample:
1. Compute E[Y|X=1, M=m] for each mediator level m.
2. Compute E[Y|X=0, M=m].
3. Integrate over the X=0 mediator distribution for NDE; over X=1 for
   NIE counterfactual.
4. Report bootstrap 95% percentile CI per estimand.

Reference implementation: Python port of VanderWeele's `CMAverse` R
package mediation formula, stripped to binary Y + categorical M.
Ships as `scripts/ab-harness/mediation-analysis.py`.

## 4. Primary metric

Per finding: **NDE point estimate + bootstrap 95% CI**, reported
alongside the existing ATE.

## 5. Secondary metrics

- NIE (indirect) estimate — reveals which mediators carry the effect.
- Proportion mediated: `NIE / TE`.
- Per-mediator NDE: NDE₁ (task_type-fixed), NDE₂ (judge_family-fixed),
  NDE₃ (output_length-fixed).

## 6. Stopping rule

N/A — bootstrap at 10k resamples is sufficient for 95% CI at ±0.01
precision. Analysis runs once per JSONL set.

## 7. Analysis plan

**Primary:**
1. Ship `scripts/ab-harness/mediation-analysis.py`.
2. Apply to existing tier-dependent JSONLs (EVAL-025, EVAL-027c).
3. Report NDE + NIE + proportion-mediated per finding.
4. Update `docs/audits/FINDINGS.md` with the mediation columns.
5. Update `docs/architecture/CHUMP_FACULTY_MAP.md` with per-module NDE alongside
   existing ATE.

**Secondary:**
- For each finding, report "dominant mediator" — the M that, when fixed,
  drives NIE closest to TE.

**Integration with RESEARCH-018, 020, 021, 024, 026:** all future live
sweeps produce mediation estimates automatically via the shipped script.

## 8. Exclusion rules

Mediation requires matched trials. If any cell has fewer than 30 matched
pairs (same task_id, differ only in X), that stratum is dropped from the
analysis. Report strata dropped.

## 9. Decision rule

**If NDE << ATE on any finding:** the existing claim is inflated.
Re-publish with mediation-adjusted effect in `docs/audits/FINDINGS.md` and update
all downstream docs. Flag as "previous aggregate estimate inflated by
mediator X — corrected NDE shown."

**If NDE ≈ ATE across findings:** no change needed; Chump's ATE framing is
defensible. Add mediation columns to FINDINGS.md as methodology upgrade.

## 10. Budget

- **Cloud:** $0 (post-hoc on existing JSONLs, no new sweeps required).
- **Wall-clock:** 1–2 days engineering + 1 day analysis.
- **Human time:** ~20 hours (script + validation + FINDINGS writeup).

## 11. Risks & mitigations

| Risk | Mitigation |
|---|---|
| No-unmeasured-confounders assumption fails | State explicitly as assumption in the writeup; note that temporal-ordering of X→M→Y is enforced by the harness pipeline (X=module is set before M=task_type assignment). |
| Insufficient strata overlap for some mediators | Strata exclusion rule §8; report which strata dropped. |
| Bootstrap CIs are overconfident at small n | Use BCa (bias-corrected accelerated) bootstrap for CIs <n=100 per stratum. |
| Analyst-choice of mediator set biases results | All 3 mediators (task_type, judge_family, output_length) preregistered here. No mediator selection after seeing results. |

---

## Deviations

*(none yet)*

---

## Result document

`docs/eval/RESEARCH-023-mediation-analysis.md` after analysis completes.
Mediation columns added to `docs/audits/FINDINGS.md` and `docs/architecture/CHUMP_FACULTY_MAP.md`.
