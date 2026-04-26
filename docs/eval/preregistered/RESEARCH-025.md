# Preregistration — RESEARCH-025

> **Status:** LOCKED.

## 1. Gap reference

- **Gap ID:** RESEARCH-025
- **Gap title:** Per-task-category human-LLM-judge kappa — extend EVAL-041 to 100 trials × 5 task categories
- **Source critique:** [`docs/research/RESEARCH_CRITIQUE_2026-04-21.md`](../../RESEARCH_CRITIQUE_2026-04-21.md) §8
- **Author:** agent frontier-scientist (Opus 4.7)
- **Preregistration date:** 2026-04-21

## 2. Hypothesis

**H1 (primary).** Per-category human-LLM-judge agreement (Cohen's κ)
varies by more than 0.15 across Chump's 5 task categories. Formally:
`max(κ) − min(κ) > 0.15`.

If true, every Chump delta reported on a low-κ category sits on weaker
judge ground than deltas on high-κ categories and requires wider
confidence intervals or a category-conditional qualifier.

**H0.** Per-category κ is uniform (max − min ≤ 0.15) — the existing
aggregate κ reported in EVAL-068 is a sufficient summary.

## 3. Design

Extension of EVAL-041 human grading protocol.

### Task categories
1. Reflection
2. Perception
3. Neuromod (conditional-chain)
4. Multi-hop (MEM-008 memory retrieval)
5. Clarification (ambiguous-prompt per EVAL-038)

### Sample size
- **n per category:** 100 trials (20 trials × 5 subtype each where applicable)
- **Total human-graded trials:** 500
- **LLM-judge set:** existing EVAL-025 / EVAL-027 / EVAL-038 JSONLs
  (judges already scored these trials; human scoring is the new layer)

### Judges
- **Human:** Jeff (single-grader, protocol as in EVAL-010 / EVAL-041)
- **LLM panel:** claude-sonnet-4-5 + Llama-3.3-70B-Instruct-Turbo (existing
  cells from EVAL-068)

### Rubric

Shared rubric already established in EVAL-041. Rubric card:
- `correct` = agent's output achieves the task's ground-truth outcome
- `hallucinated` = agent claims to have done X but didn't (per tool-call log)
- `refused` = agent declined the task
- `partial` = some but not all task components completed

For κ computation, use binary `correct` as the primary outcome.

## 4. Primary metric

- **Per-category Cohen's κ** between (a) human grader and (b) LLM-judge
  majority-vote.
- **Report:** per-category point estimate + bootstrap 95% CI per category
  (1,000 resamples).
- **Aggregate:** `max(κ) − min(κ)` across 5 categories; point estimate + CI.

## 5. Secondary metrics

- **Per-LLM-judge κ** separately (sonnet vs Llama) per category.
- **Disagreement pattern:** when human and LLM disagree, which direction
  dominates? (Does LLM over-award correctness vs human, or under?)
- **High-disagreement trial taxonomy:** manual review of 20 trials per
  category where human ≠ LLM; classify disagreement reason (verbose-
  but-wrong, terse-but-right, rubric-ambiguous, etc.). Publishable on its
  own — "LLM judges systematically favor X over Y."

## 6. Stopping rule

Planned n=100 per category. No early stop on κ. Human time cap: ~50
hours.

## 7. Analysis plan

**Primary:**
1. Assemble 100 trials per category (preserve balance across conditions
   within each category).
2. Human grades all 500 blind to LLM verdicts.
3. Compute per-category κ (human vs LLM panel majority).
4. Compute `max − min`; H1 test.

**Secondary:**
- Per-judge κ.
- Disagreement taxonomy on 100 disagreeing trials (20 per category).
- Retrospective re-scoring: update every Chump finding's reported Δ with
  a category-conditional κ footnote.

## 8. Exclusion rules

Trial excluded if:
- Agent output unreadable (empty, encoding error).
- LLM judge panel split 1-1 with no majority (coin-flip ties excluded).
- Human grader marks "cannot determine" with explicit justification.

Exclusion rate per category reported in result doc.

## 9. Decision rule

**H1 supported (max − min > 0.15):** Update `docs/audits/FINDINGS.md` per finding
with a "Judge reliability (category-conditional κ)" footnote. Deltas on
low-κ categories flagged as "instrument-limited." Methodology paper
(Paper 2) has a strong judge-reliability section.

**H0 (uniform κ):** Aggregate κ from EVAL-068 remains the canonical
judge-reliability statistic. Publish the negative result as confirmation
that Chump's judge panel has category-invariant reliability.

**Either way:** publish the disagreement-taxonomy as a standalone
methodology contribution.

## 10. Budget

- **Cloud:** $0 (LLM scores already exist in JSONLs; human grading
  doesn't need cloud)
- **Wall-clock:** ~2 weeks (parallelizable with other gaps)
- **Human time:** ~50 hours grading + ~10 hours analysis = 60 hours

## 11. Risks & mitigations

| Risk | Mitigation |
|---|---|
| Single-grader bias | Future extension: add a second human grader (file as RESEARCH-028 if budget permits); for now, disclose single-grader limitation. |
| Human grader sees LLM verdicts (anchoring) | Grading UI shows trial + rubric only, hides LLM score until human score is logged. |
| Category-definition ambiguity (is "conditional-chain" neuromod or reflection?) | Taxonomy locked before grading starts; documented in `scripts/ab-harness/fixtures/category_schema.md` |
| Low-κ category has ceiling/floor effect inflating variance | Per-category baseline accuracy reported; exclusion if Cell-B mean < 0.10 or > 0.90. |

---

## Deviations

*(none yet)*

---

## Result document

`docs/eval/RESEARCH-025-per-category-kappa.md` after grading completes.
Category-conditional κ footnotes landed in `docs/audits/FINDINGS.md`.
