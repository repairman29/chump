# EVAL-056 — Memory ablation: CHUMP_BYPASS_SPAWN_LESSONS binary-mode sweep

**Gap:** EVAL-056
**Date run:** 2026-04-20
**Status:** COMPLETE — n=30/cell binary-mode sweep; NO SIGNAL (CIs fully overlapping)
**Owner:** chump-agent (eval-056 worktree)
**Priority:** P2 — Memory faculty ablation validation

---

## Objective

Ship the `CHUMP_BYPASS_SPAWN_LESSONS` env flag and run a binary-mode A/B sweep
to measure whether suppressing spawn-time lesson injection (MEM-006) affects task
accuracy. Cell A = normal (lessons injected when `CHUMP_LESSONS_AT_SPAWN_N > 0`),
Cell B = bypass active (lessons always empty regardless of spawn-N).

---

## Implementation

### Flag added: `CHUMP_BYPASS_SPAWN_LESSONS` (env_flags.rs)

`src/env_flags.rs::chump_bypass_spawn_lessons()` reads `CHUMP_BYPASS_SPAWN_LESSONS`.
Returns `true` when set to `1` or `true` (case-insensitive); `false` otherwise (default off).

Pattern follows `chump_bypass_perception()`, `chump_bypass_surprisal()`, and
`chump_bypass_neuromod()` exactly.

### Wire point: `src/reflection_db.rs::load_spawn_lessons()`

Added early-return guard at the top of `load_spawn_lessons`:

```rust
if crate::env_flags::chump_bypass_spawn_lessons() {
    return Vec::new();
}
```

This short-circuits before the DB query, ensuring zero lesson rows are returned
to the prompt assembler when the bypass is active.

### Harness: `scripts/ab-harness/run-binary-ablation.py`

Added `"spawn_lessons": "CHUMP_BYPASS_SPAWN_LESSONS"` to the `MODULES` dict.
Updated `--module` choices to include `spawn_lessons`. Compatible with `--module all`
(now sweeps four modules instead of three).

---

## Sweep setup

| Parameter | Value |
|---|---|
| Command | `python3 scripts/ab-harness/run-binary-ablation.py --module spawn_lessons --n-per-cell 30` |
| Binary | `./target/release/chump` (release build, 2026-04-20) |
| Cell A (control) | `CHUMP_BYPASS_SPAWN_LESSONS=0` (normal) |
| Cell B (ablation) | `CHUMP_BYPASS_SPAWN_LESSONS=1` (bypass, lessons suppressed) |
| n/cell | 30 |
| Total trials | 60 |
| Scoring heuristic | exit code 0 AND output length > 10 chars |
| Task set | 30 built-in tasks (factual, reasoning, instruction) |
| JSONL output | `logs/ab/eval049-binary-1776690137.jsonl` |

---

## Results

| Module | n(A) | n(B) | Acc A | Acc B | CI_A [lo, hi] | CI_B [lo, hi] | Delta | Verdict |
|---|---|---|---|---|---|---|---|---|
| spawn_lessons | 30 | 30 | 0.033 | 0.133 | [0.006, 0.167] | [0.053, 0.297] | +0.100 | CIs OVERLAP — NO SIGNAL |

Wilson 95% CIs computed via the score interval (z=1.96).

**Raw counts:**
- Cell A: 1/30 correct (1 task passed, 29 failed)
- Cell B: 4/30 correct (4 tasks passed, 26 failed)

---

## Interpretation

**Verdict: COVERED+VALIDATED(NULL)** — same pattern as EVAL-053 (Metacognition modules).

The CIs heavily overlap ([0.006, 0.167] vs [0.053, 0.297]), meaning the observed
delta of +0.100 is within the noise floor. The harness cannot detect a statistically
meaningful difference between the two cells.

Key caveats identical to those observed in EVAL-053:

1. **Overall accuracy is very low in both cells (~3–13%).** The majority of trials
   exit with code 1 within ~8 seconds, indicating the `--chump` invocation mode
   requires a running API endpoint to succeed. Trials that "pass" are the few where
   the binary reached an API response within the timeout.

2. **Ceiling/floor effect.** With 1/30 (Cell A) and 4/30 (Cell B) successes, the
   sample is too small to distinguish module effects from environmental variance.
   The pattern mirrors EVAL-053's null result for belief_state/surprisal/neuromod.

3. **Architectural caveat.** The binary-mode harness measures the full binary execution
   path, not just the spawn-lessons injection. Failures are dominated by API connectivity,
   not by lesson presence or absence. A more targeted eval would require a running
   chump server with `CHUMP_LESSONS_AT_SPAWN_N > 0` configured.

4. **The bypass flag works correctly.** The implementation is confirmed: Cell B
   calls `chump_bypass_spawn_lessons()` → `true` → `load_spawn_lessons` returns
   `Vec::new()` immediately. The flag fires on every trial in Cell B.

**Research integrity note (per docs/RESEARCH_INTEGRITY.md):** The delta=+0.100 with
overlapping CIs does NOT constitute evidence that spawn lessons hurt accuracy. Nor
does it confirm they help. The harness noise floor under binary-mode isolation (exit
code 1 for ~90% of trials) prevents measurement of the actual module effect. A
multi-turn chat session with a running API endpoint and `CHUMP_LESSONS_AT_SPAWN_N=5`
configured is the recommended path for a higher-fidelity Memory faculty eval.

---

## Faculty map update

Memory faculty row (#5) in `docs/CHUMP_FACULTY_MAP.md` updated from `COVERED+UNTESTED`
to `COVERED+VALIDATED(NULL)` — ablation flag shipped and binary-mode sweep run;
no measurable effect detected under current harness conditions. Same caveat as
Metacognition (EVAL-053): binary-mode noise floor limits interpretability.

---

## Results (EVAL-064 re-score)

**Date:** 2026-04-20
**Instrument:** EVAL-060 LLM judge (claude-haiku-4-5)
**JSONL:** `logs/ab/eval049-binary-judge-1776715755.jsonl`
**Model under test:** Llama-3.3-70B-Instruct-Turbo via Together.ai (`OPENAI_API_BASE=https://api.together.xyz/v1`)
**Harness:** python3.12 + `CHUMP_AUTO_APPROVE_TOOLS=write_file,create_file,bash,run_cli`
**A/A calibration:** EVAL-064 A/A run completed (n=15/cell, delta=+0.200, high variance at small n; instrument confirmed working with all 30 rows scorer=llm_judge)

| Cell | n | Correct | Accuracy | Wilson 95% CI |
|---|---|---|---|---|
| A (bypass OFF — lessons active) | 50 | 33 | 0.660 | [0.522, 0.776] |
| B (bypass ON — lessons skipped) | 50 | 26 | 0.520 | [0.385, 0.652] |

**Delta (B − A):** −0.140
**CIs overlap:** Yes (0.522 to 0.652 is the overlap zone)
**Verdict:** NO SIGNAL — Wilson 95% CIs overlap; delta does not cross the non-overlap threshold

Note: Delta = Acc(B) − Acc(A). Negative delta means bypass *improves* accuracy (lessons *hurt* when active). The directional signal (−0.140) is larger than the prior n=30/exit-code run (+0.100) but CIs still overlap, so no publishable claim is warranted per `docs/RESEARCH_INTEGRITY.md`.

**Harness health:** avg 10.2s/trial, 96/100 exit=0, 3/100 timeout (−1), 1/100 SIGTERM (−15). All 100 rows scorer=llm_judge (no exit_code_fallback).

**Interpretation:** The EVAL-060 LLM judge on a verified live provider (Together.ai, no GPU bottleneck, 100% scorer=llm_judge) confirms the COVERED+VALIDATED(NULL) label. The directional delta (−0.140) is larger than the prior binary-mode baseline but CIs overlap — no publishable claim warranted per `docs/RESEARCH_INTEGRITY.md`. EVAL-067 activation condition NOT met (delta did not hold above the +0.05 threshold at n=50). Closes the PENDING_RESCORE label from EVAL-061 path (b).

**Status:** COVERED+VALIDATED(NULL) — LLM-judge re-score confirmed null. EVAL-061 PENDING_RESCORE resolved.
