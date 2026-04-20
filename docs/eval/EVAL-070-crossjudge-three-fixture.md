# EVAL-070 — Cross-judge agreement across three fixtures

**Status.** Analysis complete, 2026-04-20. No new sweeps were run; this gap
re-scores the existing EVAL-042 cross-judge JSONLs and surfaces the
per-fixture κ + per-task disagreement cluster that F4 previously only
reported for the neuromod fixture.

**Inputs.**

- `logs/ab/eval-042-crossjudge-reflection-1776659268.jsonl` (n=100)
- `logs/ab/eval-042-crossjudge-neuromod-1776659864.jsonl` (n=100)
- `logs/ab/eval-042-crossjudge-perception-1776660460.jsonl` (n=100)

Each trial was scored independently by two judges from different families:
`claude-sonnet-4-5` and `together:meta-llama/Llama-3.3-70B-Instruct-Turbo`.
Binary verdicts are thresholded at 0.5; Cohen's κ is computed over the binary
labels. Disagreement is decomposed by task-ID prefix (the fixture's own task
class tag).

## Three-fixture κ table

| Fixture     | n   | Agreement | κ @ 0.5 | Sonnet + rate | Llama + rate | Verdict                        |
| ----------- | --- | --------- | ------- | ------------- | ------------ | ------------------------------ |
| reflection  | 100 | 0.86      | **0.722** | 0.42          | 0.52         | Substantial agreement          |
| perception  | 100 | 0.75      | **0.496** | 0.44          | 0.47         | Moderate — item-level drift    |
| neuromod    | 100 | 0.71      | **0.420** | 0.50          | 0.59         | Meaningful — cluster-localised |

The three fixtures show three distinct patterns, not a single monotonic
family-bias axis.

## Per-task-prefix disagreement

**Reflection.** Low disagreement overall. Gotcha tasks disagree at 23 %,
clean at 10 %. Llama-70B is slightly more generous in both classes (direction
`llama > sonnet`). No localised cluster.

| prefix  | n  | disagree | rate | sonnet + | llama + | direction    |
| ------- | -- | -------- | ---- | -------- | ------- | ------------ |
| gotcha  | 30 | 7        | 0.23 | 14       | 21      | llama>sonnet |
| clean   | 70 | 7        | 0.10 | 28       | 31      | llama>sonnet |

**Neuromod.** Disagreement concentrates on `adaptive-*` (60 % disagreement
rate) and `dynamic-*` (27 %) — the exact conditional-chain / budget-aware
cluster identified in F3 as the lessons-block-harm task class. Trivial tasks
go the other way (Sonnet slightly more generous). This is the single-fixture
result F4 is based on and is reproduced here for completeness.

| prefix   | n  | disagree | rate | sonnet + | llama + | direction    |
| -------- | -- | -------- | ---- | -------- | ------- | ------------ |
| adaptive | 10 | 6        | 0.60 | 2        | 6       | llama>sonnet |
| dynamic  | 60 | 16       | 0.27 | 28       | 34      | llama>sonnet |
| trivial  | 30 | 7        | 0.23 | 20       | 19      | sonnet>llama |

**Perception.** A *third* pattern. The `trivial-*` class (greetings,
creative, short-answer) disagrees more (37 %) than `structured-*` (20 %).
Crucially, structured positive rates are *tied* (24 / 24) while 20 % of
items still disagree — the judges pick different items as correct rather
than differing on base rate. This is item-level drift without a global
generosity bias.

| prefix     | n  | disagree | rate | sonnet + | llama + | direction    |
| ---------- | -- | -------- | ---- | -------- | ------- | ------------ |
| trivial    | 30 | 11       | 0.37 | 20       | 23      | llama>sonnet |
| structured | 70 | 14       | 0.20 | 24       | 24      | tied         |

Top disagreement items in perception/structured: `structured-04-multi-entity`,
`structured-06-ambiguity-high`, `structured-14-mixed-risk-2`,
`structured-34-schema-change`. These are the tasks that require judgment on
ambiguous / partially-correct structured output — the exact failure mode
where two graders can both be "right" depending on the rubric's tolerance.

## Interpretation

The three fixtures instantiate three failure modes of LLM-as-judge:

1. **Reflection (κ=0.722).** Rubric is concrete enough (does the reflection
   mention the right fact? does it hedge correctly?) that judges converge.
   Usable as a single-judge signal.
2. **Perception (κ=0.496).** Rubric is concrete but tasks admit multiple
   correct answers on ambiguity / schema edge cases. Judges pick different
   items even when base rates match. *Item-level drift.*
3. **Neuromod (κ=0.420).** Rubric itself is contested (act vs. ask, hedge
   vs. commit). Disagreement localises to the conditional-chain / adaptive
   cluster and is directional (Llama > Sonnet). *Philosophical drift.*

F4 originally framed the neuromod κ as a methodological finding. The
three-fixture table upgrades that framing: **κ depends on rubric type, not
just judge family.** A fixture-agnostic "always use two judges" rule
overclaims — reflection is fine single-judge; perception needs per-item
arbitration; neuromod needs either a third judge from a different lineage
or a rubric rewrite that forces a single correct answer on the adaptive
cluster.

## Acceptance criteria checklist

- [x] Per-fixture Cohen κ at threshold 0.5 for reflection, perception, neuromod
- [x] Per-task disagreement clustering: top items + prefix-level rates
- [x] Three-fixture table with interpretation
- [x] FINDINGS.md F4 entry updated with the table (this PR)

## Caveats

- Two judges only. The three-pattern story strengthens when a third judge
  lineage (DeepSeek, Qwen-Instruct) is added — queued as EVAL-068.
- κ computed at fixed threshold 0.5. Threshold-sweep would let us separate
  "disagree on *which* items" from "disagree on *how many* items"; the
  structured/perception pattern suggests that analysis is warranted.
- n=100 per fixture is adequate for κ point estimates but CIs on κ at this
  sample size are ±0.08 — the reflection-vs-neuromod gap is well outside
  that, the perception-vs-neuromod gap is marginal.

## Source

- Raw: `logs/ab/eval-042-crossjudge-*.jsonl`
- Original single-fixture writeup: [`EVAL-042-crossjudge.md`](./EVAL-042-crossjudge.md)
- Parent finding: [`FINDINGS.md` §F4](../FINDINGS.md#f4-cross-judge-disagreement-instantiates-the-underlying-judgment)
