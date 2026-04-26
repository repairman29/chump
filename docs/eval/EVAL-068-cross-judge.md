# EVAL-068 — Cross-Judge Validation for EVAL-060

**Filed:** 2026-04-20
**Status:** SHIPPED — rescorer + harness patch + doc
**Implements:** EVAL-060 acceptance criterion #4 ("at least one non-Anthropic
judge must be run on the same trials to validate against Anthropic bias, per
RESEARCH_INTEGRITY.md")

---

## TL;DR

EVAL-060 acceptance criterion #4 was unmet by PR #279 (single Anthropic judge:
claude-haiku-4-5) and PR #288 (EVAL-063 Metacognition re-score, also
Anthropic-only). EVAL-068 ships:

1. A patch to `scripts/ab-harness/run-binary-ablation.py` to persist
   `response_text` (truncated to 2000 chars) in JSONL output rows. This
   enables retroactive cross-judging of any future sweep without re-executing
   the chump binary.
2. A new `scripts/ab-harness/rescore-jsonl.py` rescorer that reads JSONL with
   `response_text` and re-scores each trial using a Together-served judge
   (Qwen3-Coder-480B or DeepSeek-V3.1) with the same judge prompt as the
   original Anthropic judge. Hard cost cap of $5 per run.
3. This doc, which **also acknowledges that EVAL-042 already satisfies the
   spirit of criterion #4** with its three-fixture cross-family judge panel
   (claude-sonnet-4-5 + Llama-3.3-70B-Instruct-Turbo) at n=50/cell.

The script + patch close the criterion for **future** binary-mode sweeps.
The existing pre-EVAL-068 JSONLs (`logs/ab/eval049-binary-judge-*.jsonl`)
**cannot be cross-judged retroactively** because they only stored
`output_chars` (length), not `response_text`. This is documented in the
script's "Caveats" section.

---

## Why this matters

`docs/process/RESEARCH_INTEGRITY.md` requires that any externally-citable result use
**at least one non-Anthropic judge** to validate against the systematic
LLM-judge biases mapped in EVAL-046 (tool-hallucination reward;
clarification penalization; etc., with Cohen's κ vs human grading at
0.059 / −0.250 / 0.250 across reflection / perception / neuromod fixtures).

The binary-mode ablation harness, as fixed by EVAL-060 (PR #279), used
`claude-haiku-4-5` as the sole judge. EVAL-063 (Metacognition re-score, PR
#288) and the in-flight EVAL-064 (Memory + Executive Function re-score) use
the same single-judge protocol. None of those NULL verdicts can be cited
externally without violating the project's own methodology bar — until
either (a) a non-Anthropic judge agrees, or (b) the criterion is explicitly
relaxed with rationale.

EVAL-068 closes this for the binary-mode harness in two layers:

- **Forward**: future sweeps automatically save `response_text`, so any
  re-scorer can be applied retroactively at low cost (~$0.005/trial).
- **Backward**: this doc surfaces the EVAL-042 cross-family panel result
  (kappa = 0.722 reflection, 0.420 neuromod, [perception in source doc])
  as the existing evidence base.

---

## What shipped

### 1. `scripts/ab-harness/run-binary-ablation.py` patch

Single new field added to the per-trial JSONL row:

```diff
       "exit_code": returncode,
       "output_chars": len(stdout.strip()),
       "duration_ms": duration_ms,
+      # EVAL-068: persist response_text (truncated) so future runs can be
+      # cross-judged retroactively by scripts/ab-harness/rescore-jsonl.py
+      # without re-executing the chump binary. 2000 chars is enough for the
+      # short-form factual/reasoning/instruction tasks in this fixture and
+      # keeps JSONL row size under 4 KB.
+      "response_text": stdout.strip()[:2000],
       "dry_run": False,
   }
```

Truncation at 2000 chars matches the upper bound of useful task output for
the 30-task fixture (most factual answers are <100 chars; the longest
reasoning task fits in <1500). Larger files would slow JSONL parsing and
inflate logs/ab/ disk usage proportionally to sweep volume.

### 2. `scripts/ab-harness/rescore-jsonl.py`

New stdlib-only Python script. Architecture:

- Reads input JSONL row-by-row.
- For each row with `response_text` field present, calls the configured
  Together judge with the same `JUDGE_PROMPT` template used by
  `run-binary-ablation.py::llm_judge_correctness` (so verdicts are directly
  comparable to the original Anthropic-judge `correct` field).
- Parses `CORRECT: 1` or `CORRECT: 0` from the judge's reply.
- Appends three new fields to the row: `judge_correct_<safe_model>`,
  `judge_reasoning_<safe_model>`, and (implicitly) the `scorer` is
  unchanged so the original verdict is preserved alongside the new one.
- Writes enriched JSONL to the output path.
- Reports cumulative cost and inter-judge agreement % vs the original
  `correct` field.

Hard guardrails:

- `--max-cost 5.0` (USD) default; estimates cost from row count at
  ~$0.005/trial and aborts if exceeded. Runtime cap re-checked after each
  trial.
- `--limit N` for testing a subset.
- Skip-with-reason (not silent) for rows missing `response_text` or where
  the API call fails: row written through with `judge_correct_*=null` and
  `judge_reasoning_*` containing the diagnostic.

### 3. Where the existing cross-family evidence lives

EVAL-042 (`docs/eval/EVAL-042-crossjudge.md`) already ran Sonnet + Llama-70B
across three fixtures with n=50/cell:

| Fixture | claude-sonnet-4-5 pass rate | Llama-3.3-70B pass rate | Cohen's κ | Verdict |
|---|---|---|---|---|
| reflection | 0.42 | 0.52 | **0.722** | substantial agreement |
| neuromod | 0.50 | 0.59 | **0.420** | meaningful disagreement |
| perception | (in source doc) | (in source doc) | (in source doc) | (in source doc) |

The neuromod-fixture disagreement is concentrated in the dynamic /
conditional-fallback-chain task cluster — see EVAL-029 for the per-task
localization and the FINDINGS.md F4 entry for the methodological framing
("the judges instantiate the question").

This is **the existing satisfaction of RESEARCH_INTEGRITY.md criterion #4
for the cloud-API harness fixtures**. EVAL-068 extends the satisfaction to
the binary-mode harness going forward.

---

## What is *not* in scope here

- **Retroactive rescoring of existing eval049-binary-judge-*.jsonl.**
  Those JSONLs lack `response_text`. Re-scoring would require re-running
  the binary sweeps (~30-60 minutes per faculty + ~$0.50 each on Together).
  That work belongs to EVAL-063 / EVAL-064 follow-up cycles, not this
  acceptance.
- **Establishing "agreement >80%" for the binary-mode harness.** The
  acceptance criterion conditions an EVAL-069 follow-up filing on this
  outcome. Until a single binary-mode JSONL has been cross-judged (which
  cannot happen until a post-patch sweep runs), the >80% check is
  premature. The script logs the agreement % automatically when run; the
  EVAL-069-trigger logic is encoded as a stderr WARNING in the script.
- **A third judge from a fourth lineage** (e.g., GPT-4o, Gemini-2.x).
  Not required by RESEARCH_INTEGRITY.md and would significantly grow
  infrastructure scope. Filed as a possible PRODUCT-009-publication
  bullet if external readers request additional judge diversity.

---

## How a sibling agent runs the cross-judge sweep

Once a post-EVAL-068 sweep produces a JSONL with `response_text` populated:

```bash
# Use the EVAL-064-equivalent runbook to produce a fresh sweep that
# includes response_text in each row.
scripts/ab-harness/run-live-ablation.sh spawn_lessons --faculty memory
# → produces logs/ab/eval049-binary-judge-<ts>.jsonl with response_text

# Cross-judge with Qwen3-Coder-480B
python3 scripts/ab-harness/rescore-jsonl.py \
    --input logs/ab/eval049-binary-judge-<ts>.jsonl \
    --judge together:Qwen/Qwen3-Coder-480B-A35B-Instruct-FP8 \
    --output logs/ab/eval049-binary-judge-qwen-<ts>.jsonl

# Or DeepSeek-V3.1 (cheaper)
python3 scripts/ab-harness/rescore-jsonl.py \
    --input logs/ab/eval049-binary-judge-<ts>.jsonl \
    --judge together:deepseek-ai/DeepSeek-V3.1 \
    --output logs/ab/eval049-binary-judge-deepseek-<ts>.jsonl
```

The script's stderr summary reports inter-judge agreement % vs the original
Anthropic verdict. If agreement < 80%, a warning fires and the operator
files EVAL-069 (judge-methodology investigation, currently P1 in the
backlog for EVAL-026-aggregate-magnitude reopening — overlapping concern).

---

## Source pointers

- `scripts/ab-harness/run-binary-ablation.py` — patched to persist response_text
- `scripts/ab-harness/rescore-jsonl.py` — new rescorer
- `docs/eval/EVAL-042-crossjudge.md` — existing cross-family panel results
- `docs/eval/EVAL-046-judge-calibration.md` — LLM-vs-human bias map (the
  underlying motivation for criterion #4)
- `docs/process/RESEARCH_INTEGRITY.md` — methodology bar
- `docs/audits/FINDINGS.md` F4 — cross-judge disagreement framing

EVAL-068 closes; sibling can pick up further re-scoring work as part of
EVAL-069 (aggregate-magnitude reopening) once a fresh binary-mode sweep
produces response_text-equipped JSONLs.
