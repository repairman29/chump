# EVAL-060 — Binary-Mode Ablation Harness Methodology Fix

**Filed:** 2026-04-20
**Status:** SHIPPED — harness updated, A/A calibration run complete
**Implements:** `docs/audits/RED_LETTER.md` Issue #3
**Amended:** 2026-04-20 (EVAL-066) — diagnosis re-framed from "instrument
failure / systematic variance" to "provider-dependence: A/A validates the
judge, not the provider config." Original framing preserved below for
historical reference; the amendment supersedes it.

---

## Amendment (EVAL-066, 2026-04-20)

The original framing of this document attributed the A/A FAIL (delta=−0.067)
to "the instrument has systematic variance." That framing was wrong in a way
worth correcting precisely, because the wrong frame implies the wrong fix.

**The correct diagnosis is provider-dependence.** The chump binary's
`run-binary-ablation.py` invocation requires a live, reachable provider
endpoint (`OPENAI_API_BASE` + `OPENAI_API_KEY` + `OPENAI_MODEL`, or the
native Anthropic path). When the provider is misconfigured — a missing API
key, an unreachable endpoint, a serverless model that drops requests, or a
Python interpreter without the `anthropic` module installed — the binary
exits 1 with no stdout. The LLM judge then has nothing to score for that
trial. The A/A FAIL pattern at n=30 emerges from the random subset of
trials that happened to connect, not from any property of the judge or
the harness.

**The LLM judge itself is fine.** EVAL-063 re-ran all three Metacognition
modules under a verified live provider (Llama-3.3-70B on Together with
`claude-haiku-4-5` as judge, python3.12 with the `anthropic` module
installed, fixed `CHUMP_AUTO_APPROVE_TOOLS`). 99–100 of 100 trials
produced scoreable output. Cell-A accuracy was 0.60–0.68 across modules,
not 0.000–0.100. The instrument and judge are sound; the original A/A
sweep was measuring provider connectivity, not modules.

**A/A calibration is therefore a provider sanity check, not an instrument
sanity check.** When A/A shows a non-zero delta it should be read as "the
provider is producing inconsistent output" first, before any conclusion
about the instrument. The scorer (LLM judge) and the harness
(`run-binary-ablation.py` subprocess invocation logic) are both invariant
under A/A and not the variance source.

### How to avoid the same trap

Three pre-flight checks for any future binary-mode ablation sweep:

1. **`python3.12 -c 'import anthropic'`** (or whichever Python the
   harness invokes) — must succeed without error. If `anthropic` is
   missing the LLM judge silently falls back to `exit_code_fallback`
   while still recording `scorer=llm_judge` in the JSONL row, masquerading
   as a real judge call.
2. **`curl -s "$OPENAI_API_BASE/models" -H "Authorization: Bearer
   $OPENAI_API_KEY" | head`** — verify the configured provider endpoint
   actually responds with a model list before launching n=50.
3. **`scripts/ab-harness/run-live-ablation.sh <module>` runs a 3-trial
   smoke sweep first** and aborts if any trial has `exit_code != 0` or
   `output_chars <= 50`. This is the encoded form of the above two
   checks plus the "provider produces non-empty outputs" gate that
   `RESEARCH_INTEGRITY.md` now requires.

The rest of this document is the original (2026-04-20 morning) framing,
preserved unedited so the historical record is intact. Read the amendment
above as the canonical interpretation; read the rest as the artifact
the amendment supersedes.

---

## Problem statement

`scripts/ab-harness/run-binary-ablation.py` scored trials as "correct" when
`exit_code == 0 AND len(stdout) > 10`. In practice, the chump binary exits 1
on nearly every trial because the standard test environment lacks a live API
key or hits the Anthropic endpoint timeout. This produced baseline accuracies
of 0.000–0.100 across all modules (e.g., EVAL-056 Memory: Cell A acc=0.033,
EVAL-058 Executive Function: Cell A acc=0.100).

At n=30/cell, Wilson 95% CIs are approximately ±0.14, which spans the entire
[0, 1] decision space. Three faculty labels were issued on this instrument:

| Gap | Faculty | Label issued |
|-----|---------|-------------|
| EVAL-053 | Metacognition | COVERED+VALIDATED(NULL) |
| EVAL-056 | Memory | COVERED+VALIDATED(NULL) |
| EVAL-058 | Executive Function | COVERED+VALIDATED(NULL) |

Red Letter Issue #3 called this "a measurement failure rebranded as a
conclusion." NULL under the broken instrument means "measurement failed," not
"module has no effect." This is especially concerning for Metacognition because
EVAL-026 documented a negative prior signal (−0.10 to −0.16 harm) that the
exit-code instrument cannot confirm or rebut.

---

## Fix: LLM judge scoring (`--use-llm-judge`)

EVAL-060 adds a `--use-llm-judge` flag to `run-binary-ablation.py`. When set,
each trial is scored by calling `claude-haiku-4-5` with:

```
Task: {task['prompt']}
AI Response: {stdout or '(no output)'}

Did the AI response correctly address the task? Reply with exactly: CORRECT: 1 or CORRECT: 0
```

The judge can score trials where the binary exits 1 but still produced partial
output — which the exit-code scorer would mark as FAIL regardless of content.
If the judge call fails (network error, missing API key), the scorer falls back
to the exit-code heuristic for that trial and records `scorer=exit_code_fallback`
in the JSONL row.

**Key property:** The judge scores on semantic correctness, not on Rust process
exit status. A trial where chump emits a valid answer but exits 1 due to a
session-write error will now score CORRECT: 1 instead of FAIL.

---

## Fix: A/A baseline mode (`--aa-baseline`)

EVAL-060 adds `--aa-baseline` flag. When set, Cell B also runs with bypass=OFF
(same as Cell A). Both cells are identical. The expected result is delta≈0 at
any sample size.

**Purpose:** If the instrument is sound, A/A delta must be ≈0 (within Wilson
CI). If it is not ≈0, the instrument has systematic variance that will corrupt
real ablation results. Run A/A calibration before any publishable sweep.

Command:
```bash
python3 scripts/ab-harness/run-binary-ablation.py \
    --module belief_state \
    --n-per-cell 30 \
    --use-llm-judge \
    --aa-baseline
```

---

## A/A calibration results (belief_state, n=30/cell, 2026-04-20)

**Run command:**
```bash
python3 scripts/ab-harness/run-binary-ablation.py \
    --module belief_state \
    --n-per-cell 30 \
    --use-llm-judge \
    --aa-baseline \
    --binary /Users/jeffadkins/Projects/Chump/target/release/chump \
    --timeout 60
```

**JSONL:** `logs/ab/eval049-binary-judge-aa-1776699699.jsonl` (60 trial rows)

**Results:**

| Module | n(A) | n(B) | Acc A | Acc B | CI_A | CI_B | Delta | Verdict |
|--------|------|------|-------|-------|------|------|-------|---------|
| belief_state | 30 | 30 | 0.100 | 0.033 | [0.035, 0.256] | [0.006, 0.167] | −0.067 | **A/A FAIL — instrument noise > 0.05** |

**Interpretation:**

The A/A calibration failed: delta=−0.067 exceeds the ±0.05 threshold even though
both cells ran identically (bypass=OFF, same task set). Cell A happened to get
3 successful binary completions (t007, t018, t029 each connected to the API and
returned output); Cell B happened to get 1 (t010). The LLM judge scored all
"no output" trials as FAIL, so the variance is entirely driven by stochastic API
connectivity in the binary, not by any bypass flag effect.

**This is the critical diagnosis:**

> The binary-mode ablation harness fails A/A calibration even with an LLM judge.
> The noise source is not the scorer — it is the chump binary's stochastic API
> connectivity (~90–97% trials exit 1 with no output). At n=30/cell, the Wilson
> CI spans ±0.14, larger than any plausible bypass-flag effect size. No ablation
> result from this instrument can be distinguished from A/A noise.

**What this means for prior NULL labels:**

The three COVERED+VALIDATED(NULL) labels (EVAL-053 Metacognition, EVAL-056
Memory, EVAL-058 Executive Function) are not credible NULL results — they are
noise-floor artifacts. The harness cannot distinguish "module has no effect"
from "binary failed to connect for both cells equally." Adding the LLM judge
does not fix this because the judge has nothing to score when stdout is empty.

**The fix requires a running API endpoint**, so that the binary can actually
complete tasks and produce output for the judge to score. Until then:
- Binary-mode sweeps produce instrument noise, not module signal.
- The `--use-llm-judge` flag is the correct scorer once a live API is available.
- The `--aa-baseline` check is the required instrument validation step.

**Interpretation criteria:**
- delta ≈ 0.00 (|delta| ≤ 0.05) AND CIs overlap → instrument CALIBRATED
- |delta| > 0.05 OR CIs do not overlap → instrument has systematic variance (as
  seen here: A/A FAIL caused by stochastic binary connectivity, not scorer bias)

---

## Impact on existing NULL labels

The three COVERED+VALIDATED(NULL) labels from EVAL-053/056/058 were issued
under the broken exit-code instrument. Their meaning is:

> "We ran n=30/cell but the instrument could not distinguish bypass=ON from
> bypass=OFF because both cells scored ~0.033–0.100 on a floor dominated by
> API connectivity failures."

These labels are NOT revoked by EVAL-060 — the sweeps ran and the modules
are nominally covered. However, they must now carry the caveat:

> "NULL result under binary-mode exit-code scorer (EVAL-049 instrument, known
> broken per EVAL-060). Re-evaluation pending under LLM-judge instrument
> (EVAL-061 path b)."

`docs/architecture/CHUMP_FACULTY_MAP.md` has been updated to reflect this caveat. The
faculty status rows for Memory, Executive Function, and Metacognition now note
that the NULL label was issued under the broken instrument and is pending
re-evaluation.

---

## What changed in `run-binary-ablation.py`

1. **`score_trial()` signature extended** to accept `use_llm_judge: bool` and
   `task_prompt: str`. The LLM judge path is triggered when `use_llm_judge=True`.
   Returns a `scorer` field (`"llm_judge"`, `"exit_code"`, or
   `"exit_code_fallback"`) in all result dicts.

2. **`run_trial()` signature extended** to accept `use_llm_judge: bool` and
   `aa_baseline: bool`. The `aa_baseline` flag suppresses the bypass activation
   for Cell B. The `bypass_active` field in result dicts reflects the actual
   runtime state (False in aa_baseline mode for both cells).

3. **`print_summary()` extended** to display scorer label and A/A calibration
   verdict. In aa_baseline mode, the verdict column shows `A/A OK — delta≈0`
   or `A/A FAIL — instrument noise > 0.05`. Exit-code-only runs print a
   WARNING line reminding operators to use `--use-llm-judge`.

4. **`parse_args()` updated** — `--module` choices now derived from `MODULES`
   dict (includes `perception`). New flags `--use-llm-judge` and `--aa-baseline`
   documented inline and in the epilog.

5. **Output filename** includes `-judge` and/or `-aa` suffix when the
   corresponding flags are set, making JSONL files self-documenting.

6. **`llm_judge_correctness()`** added — tries `anthropic` SDK first, falls back
   to `urllib.request` HTTP call if SDK absent. Uses `claude-haiku-4-5` with
   max_tokens=20 for cost efficiency (~$0.0001/trial at haiku-4-5 pricing).

---

## Backwards compatibility

The default path (`--use-llm-judge` absent) is unchanged. `--dry-run` and CI
sweeps that do not set `ANTHROPIC_API_KEY` continue to work without any new
dependencies. The `scorer` field is new in JSONL output; existing parsers that
ignore unknown fields are unaffected.

---

## Follow-on work (EVAL-061 path b)

Re-sweep Metacognition (EVAL-053), Memory (EVAL-056), and Executive Function
(EVAL-058) under the LLM-judge instrument with n=30/cell each:

```bash
for mod in belief_state surprisal neuromod spawn_lessons blackboard; do
  python3 scripts/ab-harness/run-binary-ablation.py \
      --module $mod --n-per-cell 30 --use-llm-judge
done
```

If any module shows a non-NULL delta under the judge, update the faculty label
in `docs/architecture/CHUMP_FACULTY_MAP.md` accordingly. If Metacognition still shows NULL
under judge, that is meaningful evidence (not a measurement failure) and can be
cited per `docs/process/RESEARCH_INTEGRITY.md`.
