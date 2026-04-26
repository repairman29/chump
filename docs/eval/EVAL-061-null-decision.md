# EVAL-061 — NULL-Label Decision: Path (b) for All Three Faculties

**Date:** 2026-04-20
**Author:** Claude (eval-061 worktree)
**Gap:** EVAL-061 — Force decision on 3 NULL-validated faculties: remove or re-score
**Decision:** Path (b) for all three — reject the NULL labels, re-score under EVAL-060's LLM-judge instrument

---

## Summary

EVAL-053 (Metacognition), EVAL-056 (Memory), and EVAL-058 (Executive Function) each closed with
a `COVERED+VALIDATED(NULL)` label based on binary-mode ablation sweeps that showed no detectable
signal. This document chooses **path (b)** for all three: the NULL labels are suspended because
the scoring instrument was broken, not because the modules have no effect.

**Blocking statement:** EVAL-053, EVAL-056, and EVAL-058 labels of `COVERED+VALIDATED(NULL)` are
suspended pending EVAL-063 (Metacognition re-score) and EVAL-064 (Memory + Executive Function
re-score) under the EVAL-060 LLM-judge instrument. No module removal should be filed against any
of these three faculties until EVAL-063/064 complete.

---

## Why the NULL Labels Are Not Trustworthy

### The instrument baseline accuracy was 0–10%

The binary-mode ablation harness (`scripts/ab-harness/run-binary-ablation.py`) measures task
accuracy by invoking the `chump` binary for each trial and scoring the output. During EVAL-056
and EVAL-058 sweeps, exit-code-1 failure rates were approximately 90–97% per cell. This means
the harness was predominantly measuring whether the API connection succeeded in time — not whether
the module under test changed output quality.

Measured baselines:
- EVAL-053 (Metacognition): not reported separately; same infrastructure, same failure mode
- EVAL-056 (Memory / spawn_lessons): Cell A acc=0.033 CI [0.006, 0.167], Cell B acc=0.133 CI [0.053, 0.297]
- EVAL-058 (Executive Function / blackboard): Cell A acc=0.100 CI [0.035, 0.256], Cell B acc=0.067 CI [0.018, 0.213]

At 0–10% accuracy across both cells, a finding of "CIs overlap → no signal" is trivially expected
regardless of whether the module matters. The instrument cannot distinguish "module has no effect"
from "API connectivity failures dominate all variance."

EVAL-060's Red Letter #3 documented the noise floor explicitly: baseline accuracy 0.033 (EVAL-056)
and 0.100 (EVAL-058) — both below the level required for meaningful A/B inference.

### NULL ≠ "module has no effect"

Under a broken instrument, overlapping CIs have no inferential value. The correct interpretation
of EVAL-053/056/058 is:

> "We cannot measure whether these modules affect output quality with the current binary-mode
> harness, because API connectivity failures account for ~90–97% of result variance."

This is not the same as "the module contributes nothing." It is a measurement failure.

Proceeding to path (a) — filing removal gaps based on these results — would be removing production
code on the basis of a measuring instrument that was demonstrably non-functional for the task.
That violates the project's own research-integrity standard (`docs/process/RESEARCH_INTEGRITY.md`).

### EVAL-060's LLM-judge instrument is the correct next step

EVAL-060 is adding LLM-judge mode to `run-binary-ablation.py`. The LLM-judge replaces the
binary exit-code accuracy heuristic with a judge that evaluates response quality semantically.
This eliminates the API-connectivity-vs-module-effect confound that invalidated EVAL-053/056/058.

EVAL-063 and EVAL-064 are already filed to re-run the three faculty sweeps under the fixed
instrument. Path (b) is the only decision that does not outrun the evidence.

---

## Per-Faculty Decision Table

| Faculty | Gap ref | Modules | Decision | Rationale |
|---|---|---|---|---|
| **Metacognition** (#7) | EVAL-053 | surprisal EMA (`src/surprise_tracker.rs`), belief state (`crates/chump-belief-state/`), neuromodulation (`src/neuromodulation.rs`) | **Path (b) — re-score** | Has a documented NEGATIVE prior from EVAL-026 (−0.10 to −0.16 mean delta across four architectures). The broken instrument could neither confirm nor rebut that prior. Rushing to remove modules with an unresolved harm signal — before a valid sweep — is the worst possible outcome. Re-score under EVAL-063. |
| **Memory** (#5) | EVAL-056 | `src/reflection_db.rs::load_spawn_lessons` (MEM-006 spawn-lesson injection) | **Path (b) — re-score** | Instrument noise floor (97% exit-1 rate) makes the NULL result meaningless. spawn_lessons is a recent MEM-006 feature with no prior A/B evidence of harm. Removal without a valid measurement is premature. Re-score under EVAL-064. |
| **Executive Function** (#8) | EVAL-058 | `src/blackboard.rs` (COG-015 entity-prefetch) | **Path (b) — re-score** | Instrument noise floor same as Memory sweep. The blackboard is a multi-turn working-memory path that cannot be meaningfully exercised in single-turn binary mode — the sweep methodology was inherently inadequate for this module regardless of API connectivity. Re-score under EVAL-064 with a multi-turn test design. |

---

## Label Suspension

Effective immediately, the following labels are suspended:

- EVAL-053: `COVERED+VALIDATED(NULL)` → suspended, replaced with `COVERED+PENDING_RESCORE (see EVAL-061/063)`
- EVAL-056: `COVERED+VALIDATED(NULL)` → suspended, replaced with `COVERED+PENDING_RESCORE (see EVAL-061/064)`
- EVAL-058: `COVERED+VALIDATED(NULL)` → suspended, replaced with `COVERED+PENDING_RESCORE (see EVAL-061/064)`

The corresponding rows in `docs/architecture/CHUMP_FACULTY_MAP.md` are updated in this PR.

**No external communications should cite these three faculties as VALIDATED until EVAL-063/064
complete with the LLM-judge instrument.**

---

## Next Steps

| Task | Gap | Scope |
|---|---|---|
| Re-score Metacognition under EVAL-060 LLM-judge | EVAL-063 | surprisal EMA, belief state, neuromodulation — three separate sweeps, n≥30/cell each, binary-mode with LLM judge |
| Re-score Memory + Executive Function under EVAL-060 LLM-judge | EVAL-064 | spawn_lessons (single-turn OK), blackboard (requires multi-turn session design) |
| Complete EVAL-060 LLM-judge mode implementation | EVAL-060 | `run-binary-ablation.py --use-llm-judge` flag; unblocks EVAL-063 and EVAL-064 |

EVAL-063 and EVAL-064 are already filed. Both depend on EVAL-060.

---

## References

- `docs/eval/EVAL-048-ablation-results.md` — sweep harness confirmation; noise floor documentation
- `docs/eval/EVAL-053-metacognition-ablation.md` — Metacognition binary-mode results
- `docs/eval/EVAL-056-memory-ablation.md` — Memory binary-mode results (exit-1 rate analysis)
- `docs/eval/EVAL-058-executive-function-ablation.md` — Executive Function binary-mode results
- `docs/eval/EVAL-060-methodology-retrofit.md` — noise floor documentation and LLM-judge methodology (in progress)
- `docs/process/RESEARCH_INTEGRITY.md` — research integrity standard this decision upholds
- `docs/audits/RED_LETTER.md` — Issue #3: binary-mode noise floor documented
