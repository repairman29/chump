# EVAL-073 — Both-strict cross-judge agreement (close EVAL-072 residual)

**Status:** Closed 2026-04-20, acceptance MET.
**Depends on:** EVAL-072.
**Fixtures:** `logs/ab/eval-042-crossjudge-{reflection,perception,neuromod}-*.jsonl`.

---

## Hypothesis

EVAL-072 applied a strict-rubric prompt to the Together/Llama judge and
reached 75% overall cross-judge agreement with the (lenient-prompt)
Anthropic baseline, failing the ≥80% bar. The failure mode was
asymmetric: residual disagreement came from `Sonnet-lenient = 1`
vs `Llama-strict = 0` (partial-credit vs strict binary). The stated
follow-up was to re-score *both* judges under the strict prompt.

**Intervention.** Run `rescore-jsonl.py` twice with the identical
strict rubric on all three fixtures at n=30/faculty:

- Pass A: `--rescore-with-judge anthropic:claude-sonnet-4-5`
- Pass B: `--rescore-with-judge together:meta-llama/Llama-3.3-70B-Instruct-Turbo`

Join by `(task_id, cell)` and compute binary agreement per fixture.

---

## Result

| Fixture     | N   | Both 1 | Both 0 | Sonnet 1 / Llama 0 | Sonnet 0 / Llama 1 | Agreement |
|-------------|-----|--------|--------|--------------------|--------------------|-----------|
| reflection  | 30  | 15     | 15     | 0                  | 0                  | **100.0%** |
| perception  | 28  | 15     | 13     | 0                  | 0                  | **100.0%** |
| neuromod    | 32  | 19     | 13     | 0                  | 0                  | **100.0%** |
| **TOTAL**   | **90** | **49** | **41** | **0**          | **0**              | **100.0%** |

Acceptance criterion **≥80% overall** → **MET** (100.0%, n=90).

(Per-fixture N deviates from 30 because the same task fixture contains
rows whose `task_id` prefix puts them in a different faculty bucket —
e.g. neuromod's dynamic-* catches a few structured-reflective rows.
Join-by-task_id preserves ground truth over the original fixture-file
grouping.)

---

## Interpretation

EVAL-072 and EVAL-068 were measuring a **prompt-asymmetry artifact**,
not a true model-family disagreement. When the same strict binary
rubric is given to both judges, a 70B open-weight Llama and a
closed-weight Claude Sonnet-4.5 agree on every single row across
three very different fixture types at a rate statistically
indistinguishable from perfect.

The residual EVAL-072 gap (75% overall, perception 67%) was entirely
attributable to Sonnet's *original* (non-strict, partial-credit)
prompt scoring 0.5–0.85 on agent attempts that the strict Llama
correctly marked as failures. When Sonnet also binarizes strictly,
those same rows flip to 0 and the judges align.

This lifts the "Anthropic-only judging is insufficient for
publication" ceiling: cross-family agreement is available, it just
requires strict binary rubrics on both sides. Partial-credit judging
is where cross-family divergence hides.

**Methodological implication.** Any eval that wants to cite cross-judge
agreement as validation should (a) use the strict binary rubric on all
judges in the panel, and (b) report binarized agreement *after*
applying the threshold, not float-score correlation.

---

## Outcome

- **Acceptance criterion (≥80% overall):** MET (100.0%).
- **`docs/process/RESEARCH_INTEGRITY.md`:** updated. The "Anthropic-only
  judging is insufficient" line (in *Required Methodology Standards*)
  is preserved, but a note is added that cross-family agreement is
  achievable with strict-binary rubrics and is no longer a bottleneck
  for EVAL-042-class re-runs.
- **Cost:** ~90 Anthropic calls (~$0.50) + ~90 Together free-tier calls.
- **Follow-up:** none needed for this thread. The open question shifts
  from *"do judges agree?"* to *"do the underlying deltas survive under
  strict binary scoring?"* — that's EVAL-043's scope, not this one's.

---

## Reproduction

```bash
set -a; . .env; set +a   # loads TOGETHER_API_KEY + ANTHROPIC_API_KEY

# Pass A — strict Anthropic
python3 scripts/ab-harness/rescore-jsonl.py \
    --input logs/ab/eval-042-crossjudge-reflection-*.jsonl \
            logs/ab/eval-042-crossjudge-perception-*.jsonl \
            logs/ab/eval-042-crossjudge-neuromod-*.jsonl \
    --rescore-with-judge anthropic:claude-sonnet-4-5 \
    --output logs/ab/eval-073-sonnet-strict.jsonl \
    --max-rows 30

# Pass B — strict Llama-70B
python3 scripts/ab-harness/rescore-jsonl.py \
    --input logs/ab/eval-042-crossjudge-reflection-*.jsonl \
            logs/ab/eval-042-crossjudge-perception-*.jsonl \
            logs/ab/eval-042-crossjudge-neuromod-*.jsonl \
    --rescore-with-judge together:meta-llama/Llama-3.3-70B-Instruct-Turbo \
    --output logs/ab/eval-073-llama-strict.jsonl \
    --max-rows 30

# Join + report
python3 scripts/ab-harness/eval-073-join.py
```

Outputs: `logs/ab/eval-073-sonnet-strict.jsonl` + `logs/ab/eval-073-llama-strict.jsonl`
(90 rows each).

---

## 2026-04-26 amendment — agreement is rubric- and fixture-specific, not a general property

The 100% Sonnet/Llama agreement reported above is **specific to the EVAL-042
fixtures (reflection, perception, neuromod) under the strict binary rubric**.
It is **not** evidence that any pair of cross-family judges will agree on any
fixture under any rubric. The
[`EVAL-074-AUDIT-2026-04-26`](EVAL-074-AUDIT-2026-04-26.md) cross-judge rescore
of a different fixture (DeepSeek-V3.1 on `reflection_tasks.json` n=200) found:

- **71% Llama/Sonnet agreement, Cohen κ = 0.40** ("fair") — well below
  this project's 80% / κ ≥ 0.6 cross-judge thresholds.
- Disagreement concentrated on the **gotcha** subgroup (52% agree).
- **Llama is systematically more lenient** on that fixture: 38 Llama-pass /
  Sonnet-fail vs. 9 the other way (~4× asymmetry).

The strict binary rubric was held constant in both audits; the variable that
flipped agreement from 100% → 71% was the **fixture and the agent run being
scored**. So:

- The §"Interpretation" claim that *strict-binary cross-family judging closes
  the cross-judge gap* is true on EVAL-042 fixtures and **does not generalize**
  to all fixtures.
- The §"Methodological implication" guidance — *cite agreement only after
  binarized strict scoring* — still stands, but is now necessary, not
  sufficient. **Cross-family agreement must be re-established on each fixture
  before single-judge results from that fixture are publishable**, even when
  the strict binary rubric is in use.
- The "Anthropic-only judging is insufficient" line in
  `docs/process/RESEARCH_INTEGRITY.md` is restored to load-bearing status: cross-family
  agreement is a per-fixture empirical question, not a methodology checkbox.

This amendment does not invalidate the EVAL-073 result on its own fixtures; it
narrows the scope of the conclusion that may be carried forward from this doc.
The 100% number is a real measurement on `eval-042-crossjudge-*.jsonl` and
remains valid for that data.

Filed under [EVAL-088](../../docs/gaps.yaml).
