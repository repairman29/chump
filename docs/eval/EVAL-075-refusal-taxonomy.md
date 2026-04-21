# EVAL-075 — Failure-mode taxonomy: refusal_with_instruction axis

**Status:** COMPLETE
**Date:** 2026-04-21
**Source:** EVAL-071 JSONL (DeepSeek-V3.1 + Qwen3-235B, n=100/cell)
**Tool:** `scripts/ab-harness/eval-075-rescore.py` + updated `scoring_v2.py`

## Question

EVAL-071 preliminary showed DeepSeek-V3.1 loses -6.56pp correctness under
lesson injection. Spot-check suggested "teach-the-user" (refusal-with-
instruction, RWI) as the failure mode. Does RWI quantifiably explain the
correctness drop, and does it increase with lessons?

## New axis: `refusal_with_instruction`

Added to `scoring_v2.py` `TrialScore`. Detected by: honest-notool admission
("I don't have access...") + instruction-redirect phrasing ("how you could",
"you can:", "to find out, you", etc.). See `REFUSAL_WITH_INSTRUCTION_PATTERNS`.

## Re-score results (A/B split)

### DeepSeek-V3.1

| Cell | n | RWI | RWI% | Incorrect | Incorr RWI | Incorr RWI% |
|---|---|---|---|---|---|---|
| A (no lessons) | 100 | 15 | 15.0% | 47 | 10 | 21.3% |
| B (lessons)    | 100 | 8  | 8.0%  | 61 | 6  | 9.8%  |

### Qwen3-235B-A22B

| Cell | n | RWI | RWI% | Incorrect | Incorr RWI | Incorr RWI% |
|---|---|---|---|---|---|---|
| A (no lessons) | 100 | 15 | 15.0% | 43 | 10 | 23.3% |
| B (lessons)    | 100 | 12 | 12.0% | 47 | 10 | 21.3% |

## Conclusion — RWI does NOT explain the correctness drop

**RWI is lower under lessons, not higher.** Lesson injection reduces
teach-the-user mode by ~7pp (DeepSeek) and ~3pp (Qwen3). The correctness
drop from lessons is driven by a DIFFERENT failure mode:

- DeepSeek: +14 more incorrect in B vs A (47→61). RWI drops 7pp but other
  failure modes increase more. The remaining failures are factual errors,
  wrong reasoning, or partial-execution mistakes — not redirects to the user.
- Qwen3: +4 more incorrect in B vs A (43→47). Similarly, RWI drops slightly;
  other failures increase slightly.

**Working hypothesis:** Lessons push non-Anthropic models toward confident
attempts that fail (wrong answer, bad reasoning) rather than honest redirects.
The opposite of the Anthropic finding where lessons increase hallucinated tool
calls — here they *reduce* an honest failure mode while increasing silent
incorrect attempts.

## Action items completed

- [x] `scoring_v2.py` extended with `refusal_with_instruction` boolean axis
- [x] `eval-075-rescore.py` script for re-scoring existing JSONL data
- [x] EVAL-071 sweep re-scored; RWI breakdown documented above
- [x] `docs/gaps.yaml` EVAL-075 marked `status: done`
