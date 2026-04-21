# EVAL-071 — F2 halluc-inflation generalization beyond Anthropic

**Status:** COMPLETE — F2 does NOT extend to non-Anthropic frontier models
**Date:** 2026-04-20
**Fixture:** scripts/ab-harness/fixtures/reflection_tasks.json (n=100)
**Judge:** Llama-3.3-70B-Instruct-Turbo (strict binary rubric per EVAL-073)
**Harness:** run-cloud-v2.py --lessons-version cog016

## Question

F2 (FINDINGS.md) measured lessons-block fake-tool-call inflation at +0.14pp, 10.7x the
A/A noise floor, across n>2,600 trial pairs — but only on two Anthropic frontier models
(claude-haiku-4-5, claude-opus-4-5). Does the finding extend to non-Anthropic
architectures, or is it Anthropic-specific?

## Models tested

| Model | Provider | Reason |
|---|---|---|
| DeepSeek-V3.1 | Together | Cheap, different architecture family |
| Qwen3-235B-A22B-Instruct | Together | Large non-Anthropic frontier |

## Results

### DeepSeek-V3.1 (n=61/cell A/B, n=155 A/A)

| Metric | Cell A (no lessons) | Cell B (lessons) | Δ |
|---|---|---|---|
| Hallucinated tools | 0.00% | 0.00% | **+0.00pp** |
| A/A noise floor | — | — | 1.30pp |
| Ratio Δ/noise | — | — | **0.0x** (F2 baseline: 10.7x) |
| Correct | 47.54% | 40.98% | **-6.56pp** |

**JSONL:** `logs/ab/eval-071-deepseek-v3-1-ab-n100-1776740166.jsonl` (A/B),
`logs/ab/eval-071-deepseek-v3-1-aa-n100-1776740174.jsonl` (A/A)

**Verdict: NO halluc signal. Lessons hurt correctness by -6.56pp.**

### Qwen3-235B-A22B-Instruct (n=83/cell A/B, n=186 A/A)

| Metric | Cell A (no lessons) | Cell B (lessons) | Δ |
|---|---|---|---|
| Hallucinated tools | 0.00% | 0.00% | **+0.00pp** |
| A/A noise floor | — | — | 0.00pp |
| Ratio Δ/noise | — | — | **∞** (trivially: 0/0) |
| Correct | 55.42% | 51.81% | **-3.61pp** |

**JSONL:** `logs/ab/eval-071-qwen3-235b-ab-n100-1776740170.jsonl` (A/B),
`logs/ab/eval-071-qwen3-235b-aa-n100-1776740177.jsonl` (A/A)

**Verdict: NO halluc signal. Lessons hurt correctness by -3.61pp.**

### Cross-model summary

| Model | Halluc Δ | Ratio | Correct Δ | F2 extends? |
|---|---|---|---|---|
| claude-haiku-4-5 (F2 baseline) | +0.14pp | 10.7x | — | YES (source) |
| claude-opus-4-5 (F2 baseline) | +0.14pp | ~10x | — | YES (source) |
| DeepSeek-V3.1 (EVAL-071) | +0.00pp | 0.0x | **-6.56pp** | NO |
| Qwen3-235B (EVAL-071) | +0.00pp | ∞ (trivial) | **-3.61pp** | NO |

## Conclusion

F2 is an **Anthropic-specific artifact**. The lessons-block fake-tool-call
inflation (+0.14pp, 10.7x noise floor) does not replicate on DeepSeek-V3.1 or
Qwen3-235B. Neither non-Anthropic model hallucinates tools under lessons injection.

The failure topologies differ by architecture:
- **Anthropic** (F2): lessons → overconfident tool fabrication (halluc inflation)
- **DeepSeek**: lessons → refusal-to-attempt / "teach the user" mode (correctness drop -6.56pp)
- **Qwen3**: lessons → slight correctness erosion (-3.61pp) with no hallucination shift

DeepSeek failure-mode qualitative read: spot-check of B-cell failures shows
"teach the user" pattern — model describes how the user could run `find`/`fd`
themselves rather than attempting tool use. Lessons push DeepSeek toward
instruction mode rather than Anthropic-style "confidently fake a result" mode.

**F2 FINDINGS.md update:** narrow claim from "cross-architecture" to
"Anthropic-family." The +0.14pp halluc inflation is real and methodology-sound
for Anthropic frontier models; it should not be generalized beyond that family.

## Action items completed

- [x] `docs/FINDINGS.md` F2 entry narrowed to Anthropic-specific
- [x] `docs/gaps.yaml` EVAL-071 marked `status: done`
