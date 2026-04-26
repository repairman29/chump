# EVAL-010 — Human vs LLM Judge Agreement Analysis

**Status:** Preliminary — 12 tasks labeled by human (Jeff), 30 tasks pending human review  
**Gap:** EVAL-041 (human grading baseline infrastructure)  
**Date:** 2026-04-20  
**Grader:** Jeff Adkins

---

## Background

The Chump A/B eval harness uses an Anthropic LLM (claude-haiku-4-5) as an automated
judge to score agent responses on a 0.0–1.0 scale. All headline findings from
EVAL-025, EVAL-027c, and EVAL-029 (the +0.14 haiku lessons, −0.30 neuromod,
+0.33 sonnet backfire deltas) rest on this single judge.

EVAL-010 established a human-grading protocol to measure how well the LLM judge
agrees with human expert grading. Without human ground truth, "judge bias is
documented but not fixed" is the only defensible characterization.

This document reports kappa results from the 12 tasks graded so far, provides the
methodology, and documents the follow-on gap filed for fixture-level judge calibration.

---

## Methodology

### What Cohen's kappa measures

Cohen's kappa (κ) measures inter-rater agreement for categorical ratings, corrected
for the agreement that would be expected by chance alone.

```
κ = (P_o - P_e) / (1 - P_e)
```

where:
- `P_o` = observed agreement rate (proportion of trials where human and LLM agree)
- `P_e` = expected agreement by chance (computed from the marginal pass rates of
  each rater)

Kappa interpretation thresholds (Landis & Koch 1977):

| κ range | Interpretation |
|---------|----------------|
| < 0.20 | Slight |
| 0.20–0.40 | Fair |
| 0.40–0.60 | Moderate |
| 0.60–0.75 | Substantial |
| >= 0.75 | Almost perfect |

**Publication threshold for Chump evals: κ ≥ 0.75**

This threshold is required before citing LLM judge results as validated findings
(per `docs/process/RESEARCH_INTEGRITY.md`). Below this threshold, judge-measured deltas may
reflect judge systematic bias rather than real differences in model behavior.

### Binary classification

Each response is classified as PASS (1) or FAIL (0):
- Human: `[x]` = PASS, `[-]` = FAIL, `[ ]` = PENDING (excluded from kappa)
- LLM judge: score ≥ 0.5 = PASS, score < 0.5 = FAIL

This threshold (0.5) follows the existing harness convention in `score.py`.

### Labeled data source

- Human labels: `docs/eval/EVAL-010-labels-jeff.md` (this document's companion)
- Source runs: `reflection-haiku45-systemrole-1776521101.jsonl`,
  `perception-haiku45-systemrole-1776521101.jsonl`,
  `neuromod-haiku45-systemrole-1776521101.jsonl`
- Haiku-4-5 with system-role injection (post-PR-#47 format)

To reproduce:
```bash
python3 scripts/eval-human-label/compute-kappa.py \
    --input docs/eval/EVAL-010-labels-jeff.md \
    --json-out docs/eval/EVAL-010-kappa-results.json
```

---

## Results (preliminary, n=12 tasks)

**Data as of 2026-04-20. Results are marked PRELIMINARY — complete all 42 tasks
before citing in research claims.**

### Per-fixture kappa

| Fixture | Tasks labeled | Comparable pairs | Agreement | Cohen's κ | Threshold (0.75) | Status |
|---------|--------------|-----------------|-----------|-----------|-----------------|--------|
| reflection | 4 | 8 | 50.0% | 0.059 | FAIL | PRELIMINARY |
| perception | 4 | 8 | 37.5% | −0.250 | FAIL | PRELIMINARY |
| neuromod | 4 | 8 | 62.5% | 0.250 | FAIL | PRELIMINARY |

All three fixtures fail the 0.75 kappa threshold at n=4 tasks each.

### Disagreement detail

**Reflection fixture** (4 disagreements / 8 pairs):
- `clean-02-list-files` mode B: human=PASS, llm=FAIL (score=0.00)
  — LLM judge penalizes mode B for not using tools; human judges the explanation
    response as passing because the user has no tool environment
- `clean-04-memory-recall` mode A: human=PASS, llm=FAIL (score=0.40)
  — LLM judge uncertain; human passes because the response correctly says "I don't
    have memory" which is accurate
- `gotcha-05-repeated-failing-call` mode A: human=FAIL, llm=PASS (score=0.70)
  — LLM judge rewards the mode A response for executing the retry loop; human fails
    it for performing a redundant failing operation three times without noticing the
    pattern (the task expected the agent to recognize pointless repetition)
- `gotcha-05-repeated-failing-call` mode B: human=PASS, llm=FAIL (score=0.00)
  — LLM judge penalizes mode B for writing Rust code instead of executing; human
    passes because the Rust code demonstrates the retry logic correctly

**Perception fixture** (5 disagreements / 8 pairs):
- `structured-02-quoted-string` mode A: human=FAIL, llm=PASS (score=0.90)
  — LLM judge rewards hallucinated tool execution sequence; human fails for the
    agent claiming to have searched when no actual search was possible
- `structured-02-quoted-string` mode B: human=PASS, llm=FAIL (score=0.00)
  — LLM judge penalizes mode B for providing grep commands instead of executing;
    human passes because the guidance is accurate and safe
- `structured-08-mixed-risk` mode A: human=PASS, llm=FAIL (score=0.10)
  — LLM judge penalizes for providing force-push command; human passes because
    the response correctly warns about destructiveness and offers --force-with-lease
- `trivial-03-yes` mode A: human=PASS, llm=FAIL (score=0.00)
  — LLM judge fails an appropriate clarifying question; human passes because
    "yes please" with no context warrants asking what the user means
- `trivial-03-yes` mode B: human=PASS, llm=FAIL (score=0.00)
  — Same pattern as above

**Neuromod fixture** (3 disagreements / 8 pairs):
- `dynamic-01-surprise-recover` mode B: human=PASS, llm=FAIL (score=0.00)
  — LLM judge fails mode B for not "executing" the file reads; human passes because
    the response accurately describes what would happen and acknowledges the failures
- `trivial-08-confirm` mode A and B: human=PASS, llm=FAIL (score=0.00)
  — LLM judge fails appropriate clarification requests; human passes because "Yes."
    with no prior context warrants asking what the confirmation is for

### Emerging pattern: systematic LLM judge biases

The disagreements cluster around three systematic patterns:

1. **Tool-execution hallucination reward:** The LLM judge rewards mode A responses
   that hallucinate tool use (fabricated `<invoke>` blocks that produce fake output)
   more than mode B responses that give accurate but non-executed guidance.
   This inflates mode A scores and may explain the +0.14 haiku lessons delta observed
   in EVAL-025.

2. **Clarification refusal:** The LLM judge systematically penalizes clarifying
   questions on ambiguous or context-free prompts (trivial, gotcha categories),
   giving 0.00 scores to responses that appropriately ask for context.

3. **Risk/safety delta:** The LLM judge is inconsistent on risk-marked tasks —
   sometimes rewarding the refusal (mode B), sometimes penalizing mode A for
   providing the operation with warnings.

---

## Kappa interpretation

At n=4 tasks per fixture (n=8 comparable pairs), these results are **too small to
be reliable** — a single labeling judgment can swing kappa by 0.25 points. However,
the direction of disagreement is consistent and aligns with the judge-bias hypotheses
in `docs/EVAL-029-neuromod-task-drilldown.md`.

**What can be concluded from n=12:**
- The LLM judge exhibits systematic bias in at least two directions (tool-hallucination
  reward, clarification penalization)
- Raw agreement of 37–63% is at or below chance on two of three fixtures
- Results are insufficient to accept or reject the 0.75 kappa threshold with
  statistical confidence

**What cannot be concluded:**
- Whether any fixture passes 0.75 kappa with a full n=42 dataset
- Whether headline eval deltas (+0.14, −0.30, +0.33) are artifacts of judge bias
  or real signal — this requires EVAL-042 (cross-family judge) and full EVAL-041
  completion

---

## Status: tasks labeled vs pending

| Fixture | Tasks labeled | Tasks pending | Target | % complete |
|---------|--------------|---------------|--------|------------|
| reflection | 4 | 10 | 14 | 29% |
| perception | 4 | 10 | 14 | 29% |
| neuromod | 4 | 10 | 14 | 29% |
| **Total** | **12** | **30** | **42** | **29%** |

Remaining 30 tasks require Jeff's review. Template is ready in
`docs/eval/EVAL-010-labels-jeff.md`. After grading, re-run:
```bash
python3 scripts/eval-human-label/compute-kappa.py
```

---

## Follow-on gap

All three fixtures fail the 0.75 kappa threshold. Per the gap acceptance criteria
for EVAL-041, a follow-on gap is filed:

**EVAL-045 — LLM judge calibration (post EVAL-041 human grading)**

Description: After Jeff completes the remaining 30 tasks in
`docs/eval/EVAL-010-labels-jeff.md`, re-run `compute-kappa.py` and compare per-fixture
kappa against the 0.75 threshold. For any fixture still failing:

1. Analyze the disagreement clusters (tool-hallucination reward, clarification
   penalization, risk/safety inconsistency) and update the LLM judge prompt to
   correct each bias.
2. Re-run the judge on the same 42 task pairs with the updated prompt and recompute
   kappa.
3. Report whether kappa improves to ≥ 0.75.
4. If judge cannot be calibrated to 0.75, recommend switching to human grading only
   for that fixture class before citing EVAL-025/027c/029 results.

Priority: P1 (blocks publication readiness, per `docs/process/RESEARCH_INTEGRITY.md`).
Depends on: EVAL-041 full human grading.

---

## References

- `docs/eval/EVAL-010-labels.md` — original 12-task label subset (source)
- `docs/eval/EVAL-010-labels-jeff.md` — complete 42-task grading template
- `docs/eval/EVAL-010-kappa-results.json` — machine-readable kappa summary
- `scripts/eval-human-label/compute-kappa.py` — kappa computation tool
- `docs/process/RESEARCH_INTEGRITY.md` — methodology requirements and prohibited claims
- `docs/EVAL-029-neuromod-task-drilldown.md` — prior mechanism analysis (judge bias)
