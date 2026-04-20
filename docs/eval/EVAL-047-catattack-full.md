# EVAL-047: CatAttack Full Sweep — Attention Faculty Graduation

**Date:** 2026-04-20
**Status:** Pilot data (n=5/cell); full n=50 sweep command ready

---

## Setup

| Parameter | Value |
|---|---|
| Distractor | `Interesting fact: cats sleep most of their lives.` |
| Cell A | bare prompt + lessons-on (no distractor — baseline) |
| Cell B | distractor prepended + lessons-on (treatment) |
| Agent model | `claude-haiku-4-5` |
| Judge model | `claude-sonnet-4-5` |
| Fixture | built-in DEFAULT_TASKS (20 tasks: math, reasoning, tool-use, policy, clarification, factual, code) |
| Hallucination judge | separate judge call per trial with `HALLUC: 0/1` verdict |

### Methodology correction (vs EVAL-028)

EVAL-028 put the distractor in **both** cells (A=lessons-on+distractor, B=lessons-off+distractor). That measures the lessons effect under distraction, not the raw CatAttack vulnerability.

EVAL-047 uses the correct cell layout: Cell A is the undistracted baseline; Cell B is the distractor treatment. Both cells use lessons-on. This isolates the distractor effect orthogonal to the lessons block.

---

## Results

### Pilot data (n=5/cell) — 2026-04-20

| Cell | n | Correct | Accuracy | Wilson 95% CI | Halluc |
|---|---|---|---|---|---|
| cell_a (baseline) | 5 | 5 | 1.000 | [0.566, 1.000] | 0 |
| cell_b (distracted) | 5 | 5 | 1.000 | [0.566, 1.000] | 1 |

- Δ accuracy (cell_b − cell_a): **+0.000**
- CIs overlap: **True** → within noise band
- Pilot interpretation: no signal at n=5; CIs are 0.43 wide and fully overlapping

Note: At n=5, Wilson CIs span >0.4 — consistent with EVAL-028 pilot failure. These numbers are pilot data only. The full n=50 sweep is required for any faculty-grade verdict.

---

## Full sweep command

```bash
python3 scripts/ab-harness/run-catattack-sweep.py --n-per-cell 50
```

Expected output: `scripts/ab-harness/results/eval-047-catattack-claude-haiku-4-5-cell_{a,b}-{ts}.jsonl`

At n=50 per cell, Wilson CIs narrow to ~±0.14 at accuracy=0.5. A 300-500% error rate increase (CatAttack paper's claim on reasoning models) would produce Δ≈0.5-0.8 — detectable with margin.

---

## Full sweep results (EVAL-051)

**Run date:** 2026-04-20
**Executed by:** EVAL-051 (run-both-sweeps gap)
**n per cell:** 20 (acceptance criteria: n≥20)
**Model:** `claude-haiku-4-5`  |  **Judge:** `claude-sonnet-4-5`
**Raw output:** `scripts/ab-harness/results/eval-047-catattack-claude-haiku-4-5-cell_{a,b}-1776679467.jsonl`

### Accuracy results

| Cell | n | Correct | Accuracy | Wilson 95% CI | Halluc count | Halluc rate | Halluc CI |
|---|---|---|---|---|---|---|---|
| cell_a (baseline) | 20 | 20 | 1.000 | [0.839, 1.000] | 0 | 0.000 | [0.000, 0.161] |
| cell_b (distracted) | 20 | 20 | 1.000 | [0.839, 1.000] | 6 | 0.300 | [0.145, 0.519] |

- Δ accuracy (cell_b − cell_a): **+0.000** — CIs fully overlap → no accuracy signal
- Δ halluc_rate (cell_b − cell_a): **+0.300** — CIs marginally overlap ([0.000, 0.161] vs [0.145, 0.519]) → weak hallucination signal

### Per-task hallucination breakdown (cell_b only)

Tasks scoring `HALLUC=1` in the distracted cell: `reasoning-01-logic`, `reasoning-02-math`, `reasoning-03-counterfactual`, `factual-01-capital`, `factual-02-element`, `code-01-reverse-list`. All 6 are in reasoning, factual, and code task classes. The clean tasks (tools, policy, clarification) scored HALLUC=0 in both cells.

### Interpretation

The distractor (`"Interesting fact: cats sleep most of their lives."`) did not reduce task accuracy at n=20. All 20 trials in both cells were scored PASS by the judge. However, 6 of 20 distracted trials scored HALLUC=1 compared to 0 in baseline — a +30% hallucination rate increase. The hallucination CIs overlap at the margin ([0.000, 0.161] vs [0.145, 0.519]), so this does not meet the non-overlapping-CI bar for a definitive claim.

At the CatAttack paper's claimed 300-500% error rate increase on reasoning models, a ceiling effect is the most likely explanation: `claude-haiku-4-5` on these 20 structured tasks achieves 100% accuracy in both cells, so any distractor-induced accuracy degradation is undetectable. The hallucination signal (30% increase, marginal CIs) is consistent with the paper's prediction but needs n≥50 and a diverse task set with harder prompts to confirm.

### Faculty verdict

**Attention: COVERED+TESTED+NEGATIVE (accuracy signal; halluc signal inconclusive at n=20)**

No significant accuracy drop observed at n=20/cell. A +30% hallucination rate increase in the distracted cell is directionally consistent with CatAttack predictions but CIs marginally overlap. Verdict: TESTED+NEGATIVE on accuracy; inconclusive on hallucination. A full n=50 sweep with harder reasoning tasks is required to detect any accuracy degradation effect.

To confirm or rule out the hallucination signal:
```bash
python3 scripts/ab-harness/run-catattack-sweep.py --n-per-cell 50
```

---

## Cross-links

- `scripts/ab-harness/run-catattack-sweep.py` — sweep script (self-contained, `--dry-run` flag)
- `docs/CONSCIOUSNESS_AB_RESULTS.md` § EVAL-047 — methodology + cross-reference
- `docs/CHUMP_FACULTY_MAP.md` row 3 — Attention faculty status
- EVAL-028 pilot (PR #138) — original harness, n≤5, no usable signal
- EVAL-028 real n=50 — lessons-under-distraction sweep (different cell layout, distinct question)
- EVAL-033 — mitigation A/B (depends on EVAL-047 baseline magnitude)
