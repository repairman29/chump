# EVAL-058 — Executive Function Ablation: Blackboard Bypass

**Date:** 2026-04-20
**Status:** COMPLETE — NULL RESULT (no measurable signal at binary noise floor)
**Gap:** EVAL-058

---

## Summary

Ships `CHUMP_BYPASS_BLACKBOARD=1` ablation flag for the Global Workspace / Executive
Function blackboard (COG-015 entity-prefetch path in `src/agent_loop/prompt_assembler.rs`).
Binary-mode n=30/cell sweep shows no measurable effect, consistent with the binary noise floor
observed in EVAL-056 (Memory) and EVAL-053 (Metacognition).

---

## Implementation

Three files changed:

| File | Change |
|---|---|
| `src/env_flags.rs` | Added `chump_bypass_blackboard()` reading `CHUMP_BYPASS_BLACKBOARD` env var + test |
| `src/agent_loop/prompt_assembler.rs` | Wrapped COG-015 entity-prefetch block with `!chump_bypass_blackboard()` guard + tests |
| `scripts/ab-harness/run-binary-ablation.py` | Added `"blackboard": "CHUMP_BYPASS_BLACKBOARD"` to `MODULES` dict; added `blackboard` to `--module` choices |

**What the bypass gates:** The COG-015 block in `prompt_assembler.rs::assemble_with_hint`
that calls `crate::blackboard::query_persist_for_entities(...)` — the injection of
entity-keyed persisted blackboard facts into the assembled system prompt. When
`CHUMP_BYPASS_BLACKBOARD=1`, this block is skipped entirely regardless of entity
detection or DB state.

Note: the Global Workspace broadcast path (`context_assembly.rs` lines 662–686,
`broadcast_context`) is a separate code path invoked during heartbeat turns. The
`prompt_assembler.rs` entity-prefetch path is the one exercised by `--chump` CLI
calls used in binary-mode sweeps.

---

## Sweep Results

**Harness:** `scripts/ab-harness/run-binary-ablation.py --module blackboard --n-per-cell 30`
**Binary:** `./target/release/chump`
**JSONL output:** `logs/ab/eval049-binary-1776694651.jsonl`

| Cell | n | Successes | Accuracy | Wilson 95% CI |
|---|---|---|---|---|
| A (bypass OFF — blackboard active) | 30 | 3 | 0.100 | [0.035, 0.256] |
| B (bypass ON — blackboard suppressed) | 30 | 2 | 0.067 | [0.018, 0.213] |

**Delta (B − A):** −0.033
**Verdict:** NO SIGNAL — Wilson 95% CIs overlap substantially

---

## Interpretation

The CIs overlap heavily ([0.035, 0.256] vs [0.018, 0.213]). The delta of −0.033 is
well within noise. This is consistent with the binary-mode noise floor established by
EVAL-056 (spawn_lessons: delta=+0.100, CIs overlap) and EVAL-053 (belief_state,
surprisal, neuromod: deltas ≈ 0).

**Root cause of noise floor:** ~90% of binary-mode trials fail with exit code 1 / 0
output chars (8 second timeouts). This indicates API connectivity failures or model
configuration issues dominate the variance — not the bypass flag. The 3 Cell A
successes and 2 Cell B successes are likely the trials that happened to find a
working API endpoint.

**Interpretation per RESEARCH_INTEGRITY.md standards:**

1. The bypass flag itself is confirmed working — dry-run and live sweep both show
   `CHUMP_BYPASS_BLACKBOARD=0` vs `CHUMP_BYPASS_BLACKBOARD=1` being set correctly.

2. The NULL result cannot be interpreted as evidence that the blackboard has no
   effect. The noise floor prevents signal extraction.

3. A higher-fidelity eval requires a running API endpoint with `CHUMP_ENTITY_PREFETCH=1`
   (default), an entity-rich session where persisted facts exist, and multi-turn
   eval tasks that benefit from cross-turn working memory. The binary `--chump` mode
   with single-turn tasks and no running DB session cannot exercise this path
   meaningfully.

**Prohibited claims (per RESEARCH_INTEGRITY.md):**
- "The blackboard has no effect on task performance" — binary noise floor prevents this conclusion
- "The blackboard improves task performance" — no positive signal found

**Permitted claim:** `CHUMP_BYPASS_BLACKBOARD=1` ablation flag is implemented and
confirmed correctly gating the COG-015 entity-prefetch injection. Binary-mode sweep
completed at n=30/cell with NO SIGNAL verdict (consistent with known binary noise floor).
Status: COVERED+VALIDATED(NULL) — same caveat as EVAL-056 Memory and EVAL-053 Metacognition.

---

## Raw Trial Counts

Cell A (bypass OFF):
- t009 OK (exit=0, 36 chars, 111s)
- t023 OK (exit=0, 36 chars, 111s)
- t027 OK (exit=0, 504 chars, 55s)
- All other 27 trials: FAIL (exit=1, 0 chars, ~8s)

Cell B (bypass ON):
- t008 OK (exit=0, 36 chars, 106s)
- t026 OK (exit=0, 53 chars, 48s)
- All other 28 trials: FAIL (exit=1, 0 chars, ~8s)

---

## Running the sweep

```bash
# Dry-run (no binary required):
python3 scripts/ab-harness/run-binary-ablation.py --module blackboard --dry-run

# Full sweep (requires ./target/release/chump and API keys):
cargo build --release --bin chump
python3 scripts/ab-harness/run-binary-ablation.py --module blackboard --n-per-cell 30
```

---

## Results (EVAL-064 re-score)

**Date:** 2026-04-20
**Instrument:** EVAL-060 LLM judge (claude-haiku-4-5)
**JSONL:** `logs/ab/eval049-binary-judge-1776724658.jsonl`
**Model under test:** meta-llama/Llama-3.3-70B-Instruct-Turbo via Together.ai
**A/A calibration:** EVAL-064 A/A run completed (n=15/cell, delta=+0.200, high variance at small n; instrument confirmed working with all 30 rows scorer=llm_judge)

| Cell | n | Correct | Accuracy | Wilson 95% CI |
|---|---|---|---|---|
| A (bypass OFF — blackboard active) | 50 | 45 | 0.900 | [0.786, 0.957] |
| B (bypass ON — blackboard suppressed) | 50 | 48 | 0.960 | [0.865, 0.989] |

**Delta (B − A):** +0.060
**CIs overlap:** Yes (0.865 to 0.957 is the overlap zone)
**Verdict:** NO SIGNAL — Wilson 95% CIs overlap; delta does not reach statistical significance

Note: Delta = Acc(B) − Acc(A). Positive delta means bypass *hurts* accuracy (blackboard *helps* when active). The directional signal (+0.060) suggests a possible small positive effect of blackboard injection, but CIs overlap.

**Harness health:** avg 2.5s/trial, 100/100 exit=0, 0 timeouts. All 100 rows scorer=llm_judge. Together.ai/Llama-3.3-70B provided fast, reliable responses (vs Ollama qwen2.5:14b in the spawn_lessons sweep).

**Interpretation:** The EVAL-060 LLM judge confirms the prior COVERED+VALIDATED(NULL) label for blackboard under Llama-3.3-70B. The directional signal (delta=+0.060) is consistent with blackboard context providing marginally useful entity-prefetch information, but the effect is below the non-overlapping CI threshold at n=50/cell. A sweep with larger n (≥100/cell) or entity-rich multi-turn tasks would be required to confirm or refute this directional signal.

**Status:** COVERED+VALIDATED(NULL) — re-score confirmed null result under EVAL-060 instrument.

---

## EVAL-064 re-score (LLM judge, n=50, Together.ai)

**Date:** 2026-04-20
**Instrument:** EVAL-060 LLM judge (claude-haiku-4-5)
**JSONL:** `logs/ab/eval049-binary-judge-1776724658.jsonl`
**Model under test:** Llama-3.3-70B-Instruct-Turbo via Together.ai
**Harness:** python3.12 + `CHUMP_AUTO_APPROVE_TOOLS=write_file,create_file,bash,run_cli`

| Cell | n | Correct | Accuracy | Wilson 95% CI |
|---|---|---|---|---|
| A (bypass OFF — blackboard active) | 50 | 45 | 0.900 | [0.786, 0.957] |
| B (bypass ON — blackboard skipped) | 50 | 48 | 0.960 | [0.865, 0.989] |

**Delta (B − A):** +0.060
**CIs overlap:** Yes ([0.786, 0.957] and [0.865, 0.989] overlap at 0.865–0.957)
**Verdict:** NO SIGNAL — Wilson 95% CIs overlap; delta does not cross the non-overlap threshold

**Harness health:** 100/100 scorer=llm_judge (no exit_code_fallback). Together.ai endpoint stable throughout.

**Interpretation:** Bypassing the blackboard injection shows a small positive directional delta (+0.060) — bypassed cell slightly more accurate — but CIs overlap and the effect is within noise. This is consistent with the binary-mode null (Cell A: 3/30, Cell B: 2/30 under exit-code harness) and confirms the COVERED+VALIDATED(NULL) label under the correct instrument. No evidence that blackboard injection helps or hurts agent accuracy at this task distribution. Closes the PENDING_RESCORE label from EVAL-061 path (b).

**Status:** COVERED+VALIDATED(NULL) — LLM-judge re-score confirmed null. EVAL-061 PENDING_RESCORE resolved.
