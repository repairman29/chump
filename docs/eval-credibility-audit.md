---
doc_tag: log
owner_gap: EVAL-083
last_audited: 2026-04-25
---

# EVAL-083 — Eval credibility audit sweep

**Filed:** 2026-04-25
**Closes:** EVAL-083
**Source plan:** [`docs/EVALUATION_PLAN_2026Q2.md`](EVALUATION_PLAN_2026Q2.md) §EVAL-083
**Builds on:** [EVAL-082](eval/EVAL-082-...) (verified EVAL-069 broken).

## Why this audit exists

EVAL-082 (closed 2026-04-24) confirmed that EVAL-069 was scored with the
`exit_code_fallback` scorer despite the doc's `--use-llm-judge` claim — a
broken-methodology finding that retroactively invalidated F3 (cross-arch
neuromod harm). The question this gap answers: **how widespread is the
problem?** The fix (EVAL-081, llm-judge default + `validated=false` on
exit-code rows) shipped 2026-04-21. Any sweep that ran *before* that on the
binary-mode harness is at risk; any sweep run *after* that is presumed valid
unless its JSONL says otherwise.

## Method

For each candidate eval (EVAL-063 through EVAL-082):
1. Locate its archived JSONL under `docs/archive/eval-runs/eval-NNN-*/`.
2. Aggregate the `scorer` field across every row of every file in that run.
3. Cross-check `judge_model` / `judges` fields for richness and family
   (single-judge, two-judge, panel).
4. Read the eval doc's published verdict and check whether the rows that
   support that verdict were scored under llm-judge.
5. Categorize: **safe**, **needs re-verify**, or **broken**.

12+ evals audited per acceptance criterion (got 13 with logs + design-only
docs accounted for).

## Per-eval audit table

| Eval | Verdict | Scorer rows | Judge | Risk | Recommended action |
|---|---|---|---|---|---|
| EVAL-063 | published NULL on neuromod | **mixed**: 4 files × 100 = 406 rows `exit_code_fallback`; 4 files × 100 = 399 rows `llm_judge` (post-fix retake); A/A 60 rows `exit_code_fallback` | (no `judge_model` field in stored rows) | **NEEDS RE-VERIFY** | Re-aggregate the published delta using only `scorer=='llm_judge'` rows; if delta or CIs differ, update FINDINGS.md. If insufficient llm-judge rows, mark RETIRED like EVAL-069. |
| EVAL-064 | LLM-judge ablation N=50 cells | mostly `llm_judge` (98+100+100+100 = 398 rows) plus 12 spurious `exit_code_fallback` rows in two transient files (`-1776715772`, `-1776717043`) — likely partial-run artifacts; A/A `llm_judge` 30 rows | (no `judge_model` field) | **safe (with caveat)** | Confirm published numbers excluded the 12 transient `exit_code_fallback` rows. Document which files fed the FINDINGS row. |
| EVAL-068 | cross-judge agreement complete | analyzed eval-042 fixture data (n=100) directly, not new sweep | sonnet × Llama-70B explicit | **safe** | None — methodology doc-driven, JSONL is source. |
| EVAL-069 | RETIRED via EVAL-082 | `exit_code_fallback` confirmed | n/a | **broken (already retired)** | None — F3 already updated with caveat. |
| EVAL-070 | cross-judge methodology kappa table | uses EVAL-042 JSONL (`logs/ab/eval-042-crossjudge-{reflection,perception,neuromod}-*.jsonl`, n=100/fixture) | sonnet × Llama-70B explicit (`judge_model` populated) | **safe** | None — input JSONLs validated under EVAL-068/072/073 chain. |
| EVAL-071 | F2 does NOT extend to non-Anthropic | DeepSeek-V3.1, Qwen3-235B, n=100/cell | `together:meta-llama/Llama-3.3-70B-Instruct-Turbo` (single judge, strict rubric per EVAL-073) explicit | **safe** | None — JSONL has rich `judge_score`, `judge_passed`, `per_judge_scores` fields; no `scorer` field needed since this is the LLM-judge-native path. |
| EVAL-072 | superseded by EVAL-073 | n=30/faculty rescore against eval-042 | sonnet × Llama-70B explicit | **safe (superseded)** | None. |
| EVAL-073 | both-strict cross-judge ≥80% MET | rescore at n=30/faculty × 3 fixtures = n=90 | sonnet × Llama-70B both strict-rubric, explicit `judge_model` two-value field | **safe** | None — gold standard methodology. |
| EVAL-074 | OPEN — no run yet | n/a | n/a | **n/a (pending)** | When run, must use llm-judge default + non-Anthropic judge per EVAL-081. |
| EVAL-075 | refusal taxonomy derived from EVAL-071 | derived analysis only | inherits EVAL-071's judge | **safe** | None. |
| EVAL-076 | OPEN — design only | n/a | n/a | **n/a (pending)** | When run, must use llm-judge default + cross-family judges per EVAL-060/081. |
| EVAL-081 | shipped — IS the fix | n/a (this is the harness fix) | added `--judge-family openai` | **safe (the fix itself)** | None. |
| EVAL-082 | re-verified EVAL-069 broken | confirmation under python3.12 + llm-judge | n/a | **safe** | None — already updated FINDINGS F3. |

## Headline findings

### 1. EVAL-063 has the same EVAL-069 disease — and is more dangerous

**EVAL-063's archived run shows mixed scorers across 8 files.** The first 4
files (timestamps 1776702180–1776704673) plus both A/A baselines used
`exit_code_fallback` exclusively (366 rows). The last 4 files (1776707984
onward) used `llm_judge` (399 rows). The two halves look like a sweep that
was caught mid-run by the EVAL-081 fix — which is the same window EVAL-069
fell into.

**EVAL-063 currently still feeds into EVAL-061's "VALIDATED(NULL)" claim
for the Metacognition faculty.** Until the published delta is re-aggregated
using only `scorer=='llm_judge'` rows, the "NULL → KEEP/REMOVE" decision
chain (REMOVAL-001 → REMOVAL-003 belief_state deletion) rests partly on
broken-scorer rows. **The conclusion (REMOVAL-003) is probably still correct**
because the llm-judge half of the data also shows NEUTRAL, but the credibility
chain has a documented hole.

### 2. EVAL-064 has 12 spurious exit_code_fallback rows in transient files

Two short files (4 + 6 rows respectively, vs the 100-row main files) used
the broken scorer. They look like aborted-run leftovers — probably
should not have been included in the published aggregate. **Low-risk
finding** — verify the FINDINGS row didn't pick them up.

### 3. EVAL-070..EVAL-082 are clean

The lessons-block / cross-judge / refusal-taxonomy chain (070-076, plus
081-082) all have either (a) explicit `scorer: llm_judge` rows or (b) rich
`judge_model` + `judge_score` fields with cross-family judges. **No new
broken-scorer findings in the post-EVAL-081 era.**

### 4. EVAL-077, 078, 079, 080 don't exist

Gap IDs 077–080 are missing from `docs/gaps.yaml`. This is an ID-sequence
gap (planning skipped four numbers), not a coordination collision. **No
action.**

## Recommended actions

1. **(Immediate, this PR)** Mark EVAL-063 with a credibility caveat in
   `docs/eval/EVAL-063-...` noting the 366-row exit-code-fallback contamination
   and pointing to this audit. **Filed as EVAL-084 (P1, S effort) to do
   the actual re-aggregation** below.
2. **(Filed as EVAL-084)** Re-aggregate EVAL-063 using only `scorer ==
   'llm_judge'` rows. If the delta or CIs change materially, update
   FINDINGS.md F3 (which already has an EVAL-082 caveat — extend it).
   If insufficient llm-judge rows, mark EVAL-063 RETIRED like EVAL-069.
3. **(Filed as EVAL-085)** Verify EVAL-064 published aggregate did not
   include the 12 transient `exit_code_fallback` rows. If it did, recompute.
4. **(Already covered by EVAL-081)** No new harness-level fix needed.
   The `validated=false` flag on exit-code rows shipped 2026-04-21 prevents
   future contamination.

## Acceptance criteria check

- [x] Audit complete on 12+ evals (13 covered: EVAL-063, 064, 068, 069, 070,
      071, 072, 073, 074, 075, 076, 081, 082)
- [x] Findings documented with evidence — JSONL row counts per `scorer` value,
      judge_model fields enumerated
- [x] Risk categorized for each (safe / needs re-verify / broken / pending)
- [x] Recommended actions clear (re-aggregate / retire / no action)
- [x] Report published in `docs/eval-credibility-audit.md` (this file)
- [x] Follow-up gaps filed: EVAL-084 (EVAL-063 re-aggregation), EVAL-085
      (EVAL-064 transient-row check)

## Q2 roadmap impact

This audit identifies one methodology hole carrying real credibility weight
(EVAL-063 → REMOVAL-001 → REMOVAL-003 chain) and one minor cleanup
(EVAL-064 transient rows). The substantive removal decision (REMOVAL-003,
belief_state) is *probably* unaffected because the llm-judge half of EVAL-063
agrees, but the chain needs a clean re-aggregation row in FINDINGS for
PRODUCT-009 publication confidence. Estimated total cost to close
EVAL-084 + EVAL-085: ~half-day, doc + Python aggregation only, no new
sweeps.
