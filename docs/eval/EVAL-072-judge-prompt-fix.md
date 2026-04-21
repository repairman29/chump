# EVAL-072 — Judge-methodology fix: rubric literalism + partial-credit divergence

**Status:** Closed 2026-04-20, acceptance NOT met — see [outcome](#outcome).
**Depends on:** EVAL-068 (cross-judge agreement baseline).
**Fixture:** `logs/ab/eval-042-crossjudge-{perception,neuromod}-*.jsonl` (existing A/B data, n=100/fixture).

---

## Hypothesis

EVAL-068 measured 77.3% overall cross-judge agreement (reflection 86%,
perception 75%, neuromod 71%) between `claude-sonnet-4-5` and
`meta-llama/Llama-3.3-70B-Instruct-Turbo`. Two root causes were proposed:

1. **Rubric-literalism gap.** Sonnet scores 0 when the agent declines a
   tool-use rubric; Llama tends to score 1 for polite honest declines.
2. **Partial-credit divergence.** Llama emits 0.5 scores that binarize
   to 1 under the ≥0.5 threshold; Sonnet scores 0.1–0.4 for the same
   partial-success agent behavior.

**Intervention.** Update the judge prompt in
`scripts/ab-harness/rescore-jsonl.py` with two directives:

- *Binary only — no partial credit. Score 1 only if the task was FULLY
  completed as specified by the rubric.*
- *If the task rubric requires the agent to USE a tool (not describe
  one), an honest polite decline scores 0.*

Re-run agreement on perception + neuromod at n=30/faculty with
`together:meta-llama/Llama-3.3-70B-Instruct-Turbo` as the new judge,
comparing against the Sonnet baseline stored in `judge_score`.

---

## Result

| Fixture     | n    | Orig agreement (EVAL-068) | Post-fix agreement (EVAL-072) | Δ       |
|-------------|------|---------------------------|-------------------------------|---------|
| perception  | 30   | 75.0%                     | **66.7%**                     | **-8.3pp** |
| neuromod    | 30   | 71.0%                     | **83.3%**                     | **+12.3pp** |
| **Overall** | **60** | **73.0%**               | **75.0%**                     | +2.0pp  |

Acceptance criterion is **overall agreement ≥80%**. **NOT MET** (75.0%).

### Per-category breakdown (post-fix)

- **perception / structured:** 12/20 = 60%
- **perception / trivial:** 6/8 = 75%
- **neuromod / dynamic:** 23/30 = 77%
- **neuromod / trivial:** 2/2 = 100%

### Disagreement pattern

All disagreements on both fixtures were in the direction
`orig (Sonnet) high → new (strict Llama) = 0` (86% of disagreements).
The opposite direction `Sonnet low → Llama 1` was rare (14%).

This is consistent with the strict-rubric directive working *as
intended on Llama*: Llama now scores 0 on partial attempts, honest
inability, and adjacent-but-not-completing responses — exactly the
behaviors EVAL-068 flagged. The residual disagreement is now **Sonnet's
lenient partial-credit scores** (0.5–0.85 that binarize to 1) which
diverge from strict-Llama's 0.

---

## Interpretation

The fix succeeds at its narrow goal (Llama is now rubric-strict and
no longer gives polite-decline credit). It closes the neuromod gap
cleanly (+12pp, now ≥80%). **It fails on perception** because the
asymmetry is now on the *other side*: Sonnet is still using its
original partial-credit-friendly prompt, so the judges now disagree
in the strict-vs-lenient direction rather than the
lenient-vs-stricter direction.

The honest conclusion is that a single-sided prompt fix cannot close
the gap. To test the hypothesis that *both* judges agree under strict
rubric rules, **both** Sonnet and Llama need to be re-scored with the
strict prompt on the same fixtures. That is filed as the follow-up
gap.

---

## Outcome

- **Acceptance criterion (≥80% overall):** NOT MET (75.0%).
- **Per acceptance text:** Do **not** update `docs/RESEARCH_INTEGRITY.md` to
  permit citation of EVAL-060-derived results. The single-sided prompt
  fix is insufficient.
- **Shipping:** the judge-prompt change and the full task-fixture
  lookup (`_load_fixture` + `*_tasks.json` glob, necessary for
  neuromod rows to get scored at all) ship anyway — both are
  strictly better than the pre-fix code. The methodology for future
  cross-judge work is now strict-rubric by default.
- **Follow-up:** file a new gap for the both-strict re-score on all three
  fixtures (reflection, perception, neuromod) at n≥30/faculty. Cost:
  ~300 Anthropic judge calls (~$1-2) + ~300 Together calls (free or <$1).
- **URL-lib user-agent fix:** `_call_together` now sends
  `User-Agent: chump-eval-harness/1.0` — without it, Cloudflare returns
  HTTP 403 error-code 1010 blocking the default `Python-urllib/3.14` UA.
  This was the root cause of EVAL-068's earlier "Together 403" incident.

---

## Reproduction

```bash
set -a; . .env; set +a   # loads TOGETHER_API_KEY

python3 scripts/ab-harness/rescore-jsonl.py \
    --input logs/ab/eval-042-crossjudge-perception-*.jsonl \
            logs/ab/eval-042-crossjudge-neuromod-*.jsonl \
    --rescore-with-judge together:meta-llama/Llama-3.3-70B-Instruct-Turbo \
    --output logs/ab/eval-072-rescore-llama70b.jsonl \
    --max-rows 30
```

Output JSONL: `logs/ab/eval-072-rescore-llama70b.jsonl` (60 rows).
