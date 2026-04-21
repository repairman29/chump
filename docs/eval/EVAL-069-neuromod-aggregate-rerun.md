# EVAL-069 — Neuromod Aggregate Magnitude Rerun (EVAL-060 Instrument)

**Date:** 2026-04-21  
**Gap:** EVAL-069  
**Status:** COMPLETE — aggregate signal DOES NOT REPRODUCE  
**Instrument:** EVAL-060 LLM-judge (Claude Haiku 4.5)  
**Agent provider:** Together Qwen3-Coder-480B-A35B-Instruct-FP8  
**Harness:** `scripts/ab-harness/run-binary-ablation.py --module neuromod --n-per-cell 50 --use-llm-judge`

## Summary

EVAL-026 documented a −10 to −16 pp aggregate `is_correct` regression across 4
model families when `CHUMP_BYPASS_NEUROMOD=1`. Under the EVAL-060 fixed LLM-judge
instrument this signal does not reproduce. Delta = +0.000 with overlapping 95% CIs.

This result, combined with EVAL-063 (Llama-3.3-70B + Claude judge, same finding),
retires the aggregate-magnitude claim. F3 task-cluster localization stands as the
only confirmed neuromod finding.

## Results

| Cell | n | Acc | CI 95% lo | CI 95% hi |
|------|---|-----|-----------|-----------|
| A — control (neuromod ON) | 50 | 0.920 | 0.812 | 0.968 |
| B — ablation (neuromod bypass ON) | 50 | 0.920 | 0.812 | 0.968 |

**Delta = +0.000** (CIs completely overlap)  
**Verdict: NO SIGNAL**

## Per-task breakdown (failures only)

| Task | Acc A | Acc B | Diff | Note |
|------|-------|-------|------|------|
| t005 | 0.50 | 0.00 | −0.50 | Factual knowledge + tool hallucination; inconsistent across runs |
| t010 | 0.00 | 0.00 | +0.00 | Date arithmetic; agent hallucinates fake calculator tool |
| t028 | 0.00 | 1.00 | +1.00 | Probability calculation; inconsistent scoring |

All three failing tasks show equal or no directional bias between cells. Failures
are driven by tool hallucination and factual-recall errors unrelated to the
neuromod module.

## Methodology

- **Module:** `CHUMP_BYPASS_NEUROMOD` — ablation sets bypass=1 (disables
  neuromodulation signals: dopamine, noradrenaline, serotonin proxies)
- **Fixture:** `scripts/ab-harness/fixtures/neuromod_tasks.json` (100 tasks,
  cycling through t001–t030 for n=50)
- **Agent:** Together Qwen3-Coder-480B-A35B-Instruct-FP8 via
  `OPENAI_API_BASE=https://api.together.xyz/v1`
- **Judge:** Claude Haiku 4.5 (LLM semantic correctness scoring)
- **JSONL:** `logs/ab/eval049-binary-judge-1776739765.jsonl`

## Interpretation

Two independent re-tests under the EVAL-060 fixed instrument:

| Sweep | Agent | n/cell | Delta | Verdict |
|-------|-------|--------|-------|---------|
| EVAL-063 | Llama-3.3-70B + Claude judge | 50 | ≈ 0.000 | NO SIGNAL |
| EVAL-069 | Together Qwen3-Coder-480B + Claude Haiku | 50 | +0.000 | NO SIGNAL |

The original EVAL-026 −10 to −16 pp signal was measured under the binary
exit-code scorer (EVAL-060 finding: that scorer was broken — 27–29/30 empty
outputs under no-API conditions). The signal was a methodology artifact of the
broken instrument, not a real behavioral effect of the neuromod module.

**F3 update:** The task-cluster localization finding (dynamic/conditional chains
and monosyllabic chat tokens harm in 3 of 4 architectures) remains confirmed by
EVAL-029's per-task drilldown and is methodologically independent of the aggregate
magnitude. F3 retains the task-cluster localization claim; the aggregate magnitude
claim is retired.

## Action items completed

- [x] F3 caveat in `docs/FINDINGS.md` updated to reflect retirement of aggregate claim
- [x] `docs/gaps.yaml` EVAL-069 marked `status: done`
