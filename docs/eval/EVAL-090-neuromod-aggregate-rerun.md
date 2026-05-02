# EVAL-090 — Re-audit of EVAL-069's scorer credibility

**Date:** 2026-05-01
**Gap:** EVAL-090
**Preregistration:** [`docs/eval/preregistered/EVAL-090.md`](preregistered/EVAL-090.md)
**Status:** COMPLETE — methodological finding (M1) decisive; empirical re-run (H1/H0) deferred
**Verdict:** **Audit's broken-scorer claim is contradicted by the archived JSONL evidence.** F3
retirement was *not* based on broken-vs-broken comparison. The audit reasoned correctly that the
shebang foot-gun was a real risk, but in this specific run the user invoked the harness via
`python3.12` directly rather than through the shebang, so `scorer=llm_judge` ran correctly.

## Background

EVAL-090 was filed on 2026-04-26 from `docs/audits/INTEGRITY_AUDIT_3_EVAL_METHODOLOGY.md`, which
inferred from a shebang-vs-commit-timeline analysis that EVAL-069 must have run under the broken
`python3` (3.14, no `anthropic` module) interpreter, silently falling back to
`scorer=exit_code_fallback`. The audit concluded:

> "EVAL-069 reproduced the exit-code scorer failure, not the true effect."

If true, this would mean F3 (the neuromod aggregate-magnitude finding) was retired in
`docs/FINDINGS.md` based on a broken-vs-broken comparison and needed to be re-evaluated.

## Method

The plan (preregistration §3) was a 20-cell-per-cell ablation re-run on the same fixture
(`scripts/ab-harness/fixtures/neuromod_tasks.json`), same agent (Ollama qwen2.5:14b), same judge
(Claude Haiku 4.5), with explicit `python3.12` invocation and `--scorer llm-judge` to confirm a
working instrument.

**Before starting data collection,** we inspected the archived JSONL that EVAL-069 cited
(`docs/archive/eval-runs/eval-069-2026-04-22/eval049-binary-judge-1776739765.jsonl`) to verify the
audit's premise. The result of that inspection turned out to be the load-bearing finding; the
re-run was not needed to settle the audit's claim.

## M1: Methodological finding (decisive)

**Direct inspection of the archived EVAL-069 JSONL (100 rows, 50 per cell):**

| Field | Value |
|---|---|
| Total rows | 100 |
| `scorer=llm_judge` | **99 rows** |
| `scorer=exit_code_fallback` | 1 row |
| Cell A acc (`correct=true` / total) | 46 / 50 = **0.920** |
| Cell B acc | 46 / 50 = **0.920** |

**The "broken scorer fingerprint" is not present.** A scorer in pure
`exit_code_fallback` mode with all-empty agent output produces 100/100 rows with `correct=false`,
acc=0.000 (the 2026-04-24 file `logs/ab/eval049-binary-llmjudge-1777006276.jsonl` is an actual
example of that failure mode and is what the audit's mental model fits).

**Per-task results differ between cells** — this also rules out the "same answer to every trial"
fingerprint:

| Task | Acc A | Acc B | Δ |
|---|---|---|---|
| t005 | 0.50 | 0.00 | +0.50 |
| t028 | 0.00 | 1.00 | −1.00 |

The aggregate happens to land at 0.920 in both cells because failures balance out across the
fixture, not because the scorer awards a fixed value. **This is sampling-noise convergence, not a
broken-instrument fingerprint.**

### Timeline (UTC, verified against `git log`)

| Time | Event |
|---|---|
| 2026-04-21 02:49 | JSONL `1776739765.jsonl` written (`scorer=llm_judge` for 99/100 rows) |
| 2026-04-21 03:15 | EVAL-069 retirement commit `33f0104` |
| 2026-04-21 03:50 | INFRA-017 python3.12 shebang fix `ebdaf0e` (35 min after retirement) |

The audit correctly observed that the shebang fix landed *after* EVAL-069 closed. It incorrectly
inferred that the run therefore used `python3` (3.14, no anthropic). In fact, the harness was
invoked via `python3.12 scripts/ab-harness/run-binary-ablation.py …` directly — bypassing the
shebang. This is consistent with the writeup's own command line (preserved in
`docs/eval/EVAL-069-neuromod-aggregate-rerun.md`):

> `python3.12 scripts/ab-harness/run-binary-ablation.py --module neuromod --n-per-cell 50 --use-llm-judge`

## H1/H0: Empirical re-run (deferred)

Planned: n=20/cell ablation re-run on current `chump` binary. Outcome: sweep was inadvertently
killed mid-run by sibling cleanup commands; not restarted because M1 alone settles the gap that
EVAL-090 was filed for. The empirical question — *does the current chump binary's neuromod
ablation produce a real signal under qwen2.5:14b?* — is filed as a follow-up gap rather than
retried in scope here. See deviations log in the preregistration.

## Decision per preregistration §9

- **M1 axis: REJECTED.** Audit's mechanism claim ("EVAL-069 ran under broken scorer") is
  contradicted by the archived JSONL evidence.
- **H1/H0 axis: DEFERRED.** Re-run abandoned; filed as follow-up.

## Implications for FINDINGS.md (F3)

The AUDIT-3 caveat on F3 currently reads (paraphrased) "F3 retirement was based on broken-vs-broken
comparison." That framing should be **rewritten** to:

> "AUDIT-3 (2026-04-24) raised a credibility concern about EVAL-069's scorer based on the
> shebang-fix timeline. Direct inspection of the archived JSONL
> (`docs/archive/eval-runs/eval-069-2026-04-22/eval049-binary-judge-1776739765.jsonl`) under
> EVAL-090 (2026-05-01) confirmed that 99/100 rows ran under `scorer=llm_judge`; the user
> invoked `python3.12` directly, bypassing the broken shebang. F3's aggregate-magnitude
> retirement therefore stands on a working instrument. The independent question of whether
> the **current** chump binary's neuromod ablation produces a measurable signal is filed as
> a follow-up (see EVAL-090's follow-up gap)."

## Broader methodological lesson (the actual win)

The audit reasoned from inputs (shebang state, commit timeline) without inspecting outputs (the
JSONL evidence). Inputs *predicted* a failure mode that didn't happen because the user worked
around it manually. **Audits of past runs must read the actual JSONL evidence, not just infer from
configuration timelines.** Filed as a separate gap (see follow-up).

## Cost summary

- Cloud spend: $0 (no LLM-judge calls; all evidence from existing on-disk JSONL)
- Wall-clock: ~30 min investigation + ~30 min writeup
- Sweep wall-clock spent before kill: ~2 min smoke-test only (no full-sweep API spend)
