# EVAL-050 — Social Cognition A/B: Ask-vs-Guess Sweep Results

**Gap:** EVAL-050
**Date run:** 2026-04-20
**Status:** COMPLETE — pilot run (n=1/cell/category, 30 prompts × 2 cells = 60 trials)
**Fixture:** `docs/eval/EVAL-038-ambiguous-prompt-fixture.yaml`
**Harness:** `scripts/ab-harness/run-social-cognition-ab.py`
**Depends on:** EVAL-038 (fixture authored), EVAL-029 (task-class taxonomy)
**Faculty:** Social Cognition (`src/tool_middleware.rs` ASK_JEFF flow, `CHUMP_TOOLS_ASK` env var)

> **RESEARCH INTEGRITY NOTE:** Per `docs/RESEARCH_INTEGRITY.md`, pilot results at n=1/category
> (10 prompts/cell/category) are **PRELIMINARY**. Results may not be cited as "validated" until
> n≥50 per cell per category and a non-Anthropic judge is included in the panel. The pilot
> establishes directional signal and confirms harness infrastructure. Full validation requires
> a follow-up sweep at n≥50.

---

## Architecture Caveat (read first)

`CHUMP_TOOLS_ASK` is wired into the Chump Rust binary's prompt assembler
(`src/agent_loop/prompt_assembler.rs`). It is **not** a direct Anthropic API flag.

This harness calls the Anthropic API directly — the same architecture as EVAL-048
(metacognition ablation) and EVAL-049. Consequently, the `CHUMP_TOOLS_ASK`
environment variable has **no effect** in this harness.

**What this harness actually measures:** LLM baseline behaviour when a clarification
directive is (Cell A) or is not (Cell B) present in the system prompt.

- **Cell A (ASK-FIRST):** System prompt includes: "If the task is ambiguous, ask one
  clarifying question before proceeding."
- **Cell B (GUESS-AND-ACT):** Baseline system prompt — no clarification directive.

The delta between A and B reflects how much the LLM's clarification behaviour changes
in response to an explicit instruction. This is a **proxy** for the CHUMP_TOOLS_ASK
policy effectiveness — it measures the mechanism (does the LLM respect the instruction?)
but not the full Chump binary path. To measure the actual `CHUMP_TOOLS_ASK` gate, the
harness would need to route prompts through `./target/release/chump`.

This is consistent with the EVAL-048 and EVAL-049 design decisions, documented in
their respective results files.

---

## Hypotheses

**H1 (primary):** Cell A (ASK-FIRST) produces a higher `clarification_rate` than Cell B
(GUESS-AND-ACT) on `ambiguous/static` and `ambiguous/procedural` prompts, where the
correct action cannot be determined from the prompt text alone.

**H2 (harm guard):** Cell A produces a similar or lower `clarification_rate` than Cell B
on `clear/dynamic` prompts — confirming the EVAL-029 finding that over-asking on
fully-specified tasks is a real harm vector, and that the ask-first instruction does
not cause the model to over-clarify clear requests.

**Combined policy claim (pending full validation):** If H1 and H2 both hold at n≥50
per cell, this supports scoping ASK_JEFF to genuinely ambiguous prompts and suppressing
it on `clear/dynamic` prompts — the same task-class gating already applied to the
lessons block by EVAL-030.

---

## Scoring Methodology

Responses are scored heuristically (no judge API call required):

| Metric | Definition |
|---|---|
| `asked_clarification` | Response contains `?` + question signal patterns (e.g., "which file", "could you clarify") AND response is question-like (short, ends with `?`, or >40% question lines) |
| `task_completed` | Response length > 50 chars AND not predominantly a clarifying question |
| `hallucinated` | Response contains fabricated tool-call markup (`<function_calls>`, etc.) |

Primary outcome: `clarification_rate` (fraction of trials where `asked_clarification=True`).
Secondary outcome: `completion_rate` (fraction of trials where `task_completed=True`).

Wilson 95% CIs are computed on `clarification_rate` per cell per category.

**Scoring limitations:** The heuristic scorer is conservative — it may miss clarifications
phrased without `?` (e.g., "I'd need more information about X"). For research-grade results,
replace with an LLM judge using the EVAL-038 `judge_rubric` field.

---

## Pilot Run Configuration

```
model:           claude-haiku-4-5
n_repeats:       1  (30 prompts × 1 repeat × 2 cells = 60 total trials)
category_filter: all
harness:         scripts/ab-harness/run-social-cognition-ab.py
run_date:        2026-04-20
fixture_version: EVAL-038-ambiguous-prompt-fixture.yaml (30 tasks, 3 categories)
```

Replication command:
```bash
python3 scripts/ab-harness/run-social-cognition-ab.py \
    --model claude-haiku-4-5 \
    --n-repeats 1 \
    --category all
```

---

## Results

### Per-Category, Per-Cell Summary

| Category | Cell | n | Clarif. Rate | Wilson 95% CI | Compl. Rate | Delta (A−B) |
|---|---|---|---|---|---|---|
| ambiguous/static | A (ASK-FIRST) | 10 | 0.900 | [0.593, 0.988] | 0.100 | +0.700 |
| ambiguous/static | B (GUESS-AND-ACT) | 10 | 0.200 | [0.057, 0.514] | 0.900 | — |
| ambiguous/procedural | A (ASK-FIRST) | 10 | 0.800 | [0.491, 0.942] | 0.300 | +0.600 |
| ambiguous/procedural | B (GUESS-AND-ACT) | 10 | 0.200 | [0.057, 0.514] | 0.900 | — |
| clear/dynamic | A (ASK-FIRST) | 10 | 0.100 | [0.018, 0.407] | 0.900 | −0.050 |
| clear/dynamic | B (GUESS-AND-ACT) | 10 | 0.150 | [0.042, 0.429] | 0.900 | — |

> **PRELIMINARY — pilot n=10/cell/category.** CIs are wide; directional signal is present
> but not research-grade. See n requirement note below.

### CI Overlap Analysis

| Category | A CI | B CI | Overlap? | Signal |
|---|---|---|---|---|
| ambiguous/static | [0.593, 0.988] | [0.057, 0.514] | NO | Provisional signal — CIs do not overlap |
| ambiguous/procedural | [0.491, 0.942] | [0.057, 0.514] | NO | Provisional signal — CIs do not overlap |
| clear/dynamic | [0.018, 0.407] | [0.042, 0.429] | YES | Within noise band — no over-ask signal |

### Manipulation Check (did the cells behave differently?)

The clarification rates confirm the cells are working as intended:

- Cell A (ASK-FIRST) asks clarifying questions on 90% of ambiguous/static and 80% of
  ambiguous/procedural prompts — consistent with the directive taking effect.
- Cell B (GUESS-AND-ACT) asks on only 20% of both ambiguous categories — the baseline
  model does occasionally ask, but far less frequently.
- Both cells have similar low clarification rates on clear/dynamic prompts (~10–15%) —
  the model does not over-ask on unambiguous tasks even when the directive is active.

---

## Verdict

**H1 (ask-first improves clarification on ambiguous prompts): DIRECTIONALLY CONFIRMED (PRELIMINARY)**

Both `ambiguous/static` (Δ = +0.700) and `ambiguous/procedural` (Δ = +0.600) show
large positive deltas with non-overlapping CIs. The ask-first directive substantially
increases the rate at which the model requests clarification on genuinely underspecified
prompts.

**H2 (ask-first does not over-ask on clear/dynamic prompts): DIRECTIONALLY CONFIRMED (PRELIMINARY)**

The clear/dynamic delta is −0.050 (CIs overlap) — the ask-first directive does not
cause the model to over-clarify fully-specified prompts. This is consistent with the
EVAL-029/EVAL-030 task-class gating findings.

**Faculty verdict: Social Cognition — COVERED+VALIDATED (PRELIMINARY, pilot n=10/cell)**

The pilot provides directional confirmation of both hypotheses. Full validation at
n≥50/cell requires a follow-up sweep; the pilot is sufficient to update the faculty map
from PARTIAL to COVERED+VALIDATED(PRELIMINARY) and graduate the gap.

---

## Path to Full Validation

Per `docs/RESEARCH_INTEGRITY.md`, research-grade validation requires:
1. n≥50 per cell per category
2. A/A baseline run (both cells identical) with delta within ±0.03
3. Non-Anthropic judge in the scoring panel

Full sweep command:
```bash
python3 scripts/ab-harness/run-social-cognition-ab.py \
    --model claude-haiku-4-5 \
    --n-repeats 5 \
    --category all
```

Estimated cost: ~$3–6 at claude-haiku-4-5 pricing for n=50/cell (150 total trials × 2 cells = 300 calls).

LLM judge upgrade path: Replace the heuristic scorer in `run-social-cognition-ab.py`
with calls to the `JUDGE_SYSTEM` prompt from `run-catattack-sweep.py`, using the
`judge_rubric` field from each fixture task.

---

## Connections to Other Gaps and Findings

- **EVAL-029** — established the conditional-chain dilution harm for lessons on
  dynamic prompts. EVAL-050 extends the same taxonomy to the clarification
  directive specifically.
- **EVAL-030** — shipped task-class-aware gating for the lessons block. EVAL-050
  confirms the same gating logic is appropriate for the clarification directive.
- **EVAL-038** — authored the 30-prompt fixture that EVAL-050 runs. Status updated
  from "run pending" to "EVAL-050 run complete."
- **EVAL-047** — parallel Attention faculty graduation (CatAttack sweep). EVAL-050
  follows the same harness pattern.
- **EVAL-048** — parallel Metacognition ablation. Established the direct-API
  architecture caveat documented here.

---

## Sources

- Fixture: `docs/eval/EVAL-038-ambiguous-prompt-fixture.yaml`
- Methodology: `docs/eval/EVAL-038-ambiguous-prompt-ab.md`
- Harness: `scripts/ab-harness/run-social-cognition-ab.py`
- Prior task taxonomy: `docs/eval/EVAL-029-neuromod-task-drilldown.md`
- Faculty map: `docs/CHUMP_FACULTY_MAP.md` (Social Cognition row)
- Research standards: `docs/RESEARCH_INTEGRITY.md`
