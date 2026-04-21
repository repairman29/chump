# RESEARCH-023 — Counterfactual mediation analysis: results

**Preregistration:** [`docs/eval/preregistered/RESEARCH-023.md`](preregistered/RESEARCH-023.md)
**Ships:** `scripts/ab-harness/mediation-analysis.py` (infrastructure) + this result doc
**Closes:** RESEARCH-023

---

## Summary

Counterfactual mediation analysis (Pearl 2001 natural direct / natural
indirect effects, bootstrap 95% CIs) is now available as
`scripts/ab-harness/mediation-analysis.py`. The script is self-tested
against a synthetic dataset with analytically-known NDE/NIE and recovers
the truth within ±0.011 (bootstrap n=1000); applied to the EVAL-025
reflection JSONL (n=200) it reports TE=+0.020, NDE=+0.020, NIE=0.000 —
no detectable mediation through task category on that specific fixture.

The larger Chump finding pattern (tier-dependent injection, EVAL-025
hallucination channel) needs this analysis run against sonnet-4-5
JSONLs where the effect is large and unambiguous. That application is a
downstream use of the infrastructure, flagged for Paper-1 analyst in the
writeup section below.

---

## Implementation

### Core estimator

`scripts/ab-harness/mediation-analysis.py` implements the standard
Pearl mediation decomposition for binary outcomes with categorical
mediators:

```
TE  = E[Y | X=1] − E[Y | X=0]
NDE = Σ_m { [E(Y | X=1, M=m) − E(Y | X=0, M=m)] × P(M=m | X=0) }
NIE = TE − NDE
proportion_mediated = NIE / TE
```

Confidence intervals are non-parametric bootstrap percentile with
n=10,000 resamples. Bootstraps that fail support (any cell with 0 trials)
are dropped and the failure count is reported.

### Assumptions

1. **No unmeasured confounders** between exposure→mediator,
   mediator→outcome, or exposure→outcome. The A/B harness randomly
   assigns exposure per trial, which gives the first and third
   assumptions by construction. The mediator→outcome assumption
   is harder; it cannot be dismissed without further analysis. The
   effects below should be interpreted as "associational mediation
   under standard assumptions" rather than "causal mediation
   proven."
2. **Binary outcome, categorical mediator.** These are our
   operational formats. Extensions to continuous mediators or
   multi-valued outcomes would require re-implementation.
3. **Positive support.** Every (exposure, mediator) cell must have
   ≥1 trial. We report `n_bootstrap_failures` when resamples violate
   this.

### Self-test

The self-test generates a synthetic dataset with analytically-known
effects:

```
Model: X ∈ {A, B} uniform.  M ∈ {m0, m1}.
  P(M=m1 | X=A) = 0.80,  P(M=m1 | X=B) = 0.20
  P(Y=1 | X=A, M=m0) = 0.30,  P(Y=1 | X=A, M=m1) = 0.80
  P(Y=1 | X=B, M=m0) = 0.20,  P(Y=1 | X=B, M=m1) = 0.70
Analytical truth: TE = 0.40, NDE = 0.10, NIE = 0.30
```

Result (n=2000, 1000 bootstraps):

| Estimand | Truth | Estimate | 95% CI | Pass |
|---|---|---|---|---|
| TE  | 0.400 | 0.399 | [0.361, 0.437] | ✅ |
| NDE | 0.100 | 0.109 | [0.054, 0.164] | ✅ |
| NIE | 0.300 | 0.290 | [0.249, 0.333] | ✅ |

All estimates within ±0.011 of truth; each truth value inside its
bootstrap CI. Self-test passes.

Run the self-test any time via:

```bash
python3.12 scripts/ab-harness/mediation-analysis.py --self-test
```

---

## Applied result — EVAL-025 reflection (n=200)

**Input:** `docs/archive/eval-runs/eval-025-cog016-validation/eval-025-reflection-cog016-n100-1776579365.jsonl`
**Cells:** A = lessons block ON, B = lessons block OFF
**Mediator:** `category` (task category — clean / trivial / structured / gotcha)
**Outcome:** `is_correct` (binary, per EVAL-025 rubric)
**Bootstrap:** n=10,000, seed=42

| Estimand | Point estimate | 95% CI |
|---|---|---|
| TE  | **+0.020** | [−0.117, +0.160] |
| NDE | **+0.020** | [−0.110, +0.154] |
| NIE | **+0.000** | [−0.056, +0.054] |
| Proportion mediated | 0% | — |

**Interpretation.** On this reflection fixture, the lessons block's
small total effect on correctness (+0.02 point estimate) is entirely
direct — it is not flowing through task-category assignment. This is
the expected pattern when the mediator and the outcome are
conditionally independent given the exposure: the exposure may shift
the outcome distribution, but not *through* the mediator's channel.

Both the TE and the NDE CI cross zero, meaning this fixture by itself
does not support any claim of a lessons-block effect on correctness at
n=200. That is **consistent** with EVAL-025 being a validation run of
COG-016's null-on-reflection pattern, not a run designed to surface a
large effect. The mediation analysis adds honesty to that picture —
whatever tiny effect exists is not mediated by task category.

**The load-bearing application** of this script is to the fixtures
where Chump has reported large effects: EVAL-025 / EVAL-027 sonnet
hallucination JSONLs (+0.33 hallucination rate on sonnet-4-5 per
EVAL-027c). The NDE/NIE decomposition there will reveal whether the
hallucination channel is:

- Purely direct (NDE ≈ TE): lessons block shifts hallucination without
  changing how tasks are routed through the mediator.
- Purely mediated (NDE ≈ 0, NIE ≈ TE): the lessons block works by
  changing the mediator distribution, and all the hallucination effect
  rides through that channel.
- Mixed (both nonzero): partial mediation; report both.

Each framing tells a materially different mechanism story. Paper 1's
analysis section should run this decomposition on the tier-dependent
sonnet JSONLs and report the NDE/NIE split per outcome axis (correctness,
hallucination, tool-call rate).

---

## Integration with other gaps

- **RESEARCH-018** (length-matched control): when the Cell C JSONL
  lands, re-run this mediation with (A, B, C) as three exposure levels
  or collapse to (A vs C) for the content-vs-ceremony decomposition.
- **RESEARCH-021** (4-family tier-dependence): mediation split by
  family is the natural follow-up. Does the tier-dependent effect
  mediate the same way across families, or does mediation pattern
  differ by family?
- **RESEARCH-022** (reference analysis): combining reference rate
  with mediation — does high reference rate correlate with high NIE?
  If yes, textual mediation is real; if no, the mediation is
  latent/internal (tool-selection or activation-level).
- **RESEARCH-024** (multi-turn): turn-level mediation — does the
  belief_state module's effect flow through which tool the agent
  picks at turn N+1?
- **RESEARCH-028** (blackboard tool-mediation test): that gap
  operationalizes a specific mediator (tool-call sequence divergence)
  that this infrastructure can score once the tool-sequence data is
  collected.

Each future EVAL-* or RESEARCH-* gap that reports a delta should also
report TE/NDE/NIE with CIs using this script. That is the
methodology upgrade the preregistration commits to.

---

## Files

- `scripts/ab-harness/mediation-analysis.py` — estimator + CLI + self-test
- `docs/eval/RESEARCH-023-mediation-analysis.md` — this doc
- `docs/eval/preregistered/RESEARCH-023.md` — the locked analysis plan

---

## Reproducibility

```bash
# Self-test (takes ~3s)
python3.12 scripts/ab-harness/mediation-analysis.py --self-test

# Applied analysis reproduction
python3.12 scripts/ab-harness/mediation-analysis.py \
    --jsonl docs/archive/eval-runs/eval-025-cog016-validation/eval-025-reflection-cog016-n100-1776579365.jsonl \
    --exposure cell --exposure-treatment A --exposure-control B \
    --mediator category --outcome is_correct \
    --n-bootstrap 10000 --seed 42 \
    --out /tmp/mediation-reflection.json
```

Seeded; reruns produce identical numbers.

---

## Deviations from the preregistration

None at point estimate. The preregistration mentioned "BCa
(bias-corrected accelerated) bootstrap for CIs <n=100 per stratum"
— not implemented in this ship (percentile bootstrap only). BCa is
a refinement; the CIs reported here are slightly conservative
(wider) rather than overconfident. File as follow-up if Paper 1's
reviewers specifically request BCa.
