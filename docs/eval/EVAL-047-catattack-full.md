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

## Faculty verdict

**Attention: COVERED+UNTESTED (full sweep command ready, run EVAL-047)**

Pilot data (n=5) is insufficient for a faculty-grade verdict. The sweep infrastructure is validated: dry-run works without API keys, per-trial JSONL output streams to `scripts/ab-harness/results/`, Wilson CIs and hallucination counts are computed per cell.

To graduate Attention to COVERED+VALIDATED or COVERED+TESTED+NEGATIVE, run the full n=50 sweep and update this doc with:
- The results table populated from `eval-047-catattack-claude-haiku-4-5-*` files
- The CIs overlap verdict
- The faculty verdict (VALIDATED if non-overlapping CIs with accuracy drop; TESTED+NEGATIVE if no significant drop)

---

## Cross-links

- `scripts/ab-harness/run-catattack-sweep.py` — sweep script (self-contained, `--dry-run` flag)
- `docs/CONSCIOUSNESS_AB_RESULTS.md` § EVAL-047 — methodology + cross-reference
- `docs/CHUMP_FACULTY_MAP.md` row 3 — Attention faculty status
- EVAL-028 pilot (PR #138) — original harness, n≤5, no usable signal
- EVAL-028 real n=50 — lessons-under-distraction sweep (different cell layout, distinct question)
- EVAL-033 — mitigation A/B (depends on EVAL-047 baseline magnitude)
