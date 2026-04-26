# EVAL-065 — Pre-Registered Analysis Plan
## Social Cognition n≥200/cell Strict-Judge Sweep

**Gap:** EVAL-065
**Filed:** 2026-04-20
**Status:** PRE-REGISTERED (sweep not yet started)
**Harness:** `scripts/ab-harness/run-social-cognition-ab.py`
**Runner:** `scripts/soak/eval-065-runner.sh`
**Depends on:** EVAL-062 (strict-judge diagnostic confirming ceiling compression)

> Pre-registration means this plan is committed before the sweep runs.
> Results will not be post-hoc reframed to fit a different story.
> Per `docs/process/RESEARCH_INTEGRITY.md`: document the final verdict either way.

---

## Background

Three prior sweeps (EVAL-050, EVAL-055, EVAL-057, EVAL-062) have all left Social
Cognition faculty (#10) at **PRELIMINARY** status. EVAL-062 (n=10/cell, strict
judge) diagnosed the root cause: ceiling compression. `claude-haiku-4-5` asks
clarifying questions ~90–100% of the time on ambiguous prompts whether or not the
ASK-FIRST directive is present. The effect is real but the baseline is so high that
statistical separation (non-overlapping 95% Wilson CIs) requires a large n to
distinguish A=1.000 from B=0.900.

EVAL-062's own text and the faculty map both state: **"Definitive verdict requires
n≥200/cell."** This gap runs that sweep.

---

## Harness Configuration

| Parameter | Value | Rationale |
|---|---|---|
| `--n-repeats` | 7 | 7 × 30 fixture tasks = 210 trials/cell ≥ 200 required |
| `--category` | all | All three categories (ambiguous/static, ambiguous/procedural, clear/dynamic) |
| `--model` | claude-haiku-4-5 | Same model as all prior sweeps — consistency |
| `--use-llm-judge` | yes | LLM judge required for strict rubric |
| `--strict-judge` | yes | Only explicit clarifying questions score CLARIFIED: 1 |
| `--judge-model` | claude-haiku-4-5 | Same judge as EVAL-062 |
| Total trials | 420 | 210/cell × 2 cells |

**Reproducible call:**
```bash
python3 scripts/ab-harness/run-social-cognition-ab.py \
    --n-repeats 7 \
    --category all \
    --model claude-haiku-4-5 \
    --use-llm-judge \
    --judge-model claude-haiku-4-5 \
    --strict-judge
```

Or via the soak runner (detached):
```bash
nohup scripts/soak/eval-065-runner.sh > logs/eval-065/runner.log 2>&1 &
```

---

## Cost Estimate

| Component | Count | Rate | Cost |
|---|---|---|---|
| Subject calls (haiku input ~300 tok) | 420 | $0.80/M | $0.10 |
| Subject calls (haiku output ~150 tok) | 420 | $4.00/M | $0.25 |
| Judge calls (haiku input ~500 tok) | 420 | $0.80/M | $0.17 |
| Judge calls (haiku output ~10 tok) | 420 | $4.00/M | $0.02 |
| **Total** | | | **~$0.54** |

**Abort threshold: $5.** If actual cost approaches $5 mid-run, stop and document.

---

## Primary Hypotheses (pre-registered)

**H1 (directional):** Cell A (ASK-FIRST directive) produces a higher `clarification_rate`
than Cell B (no directive) on `ambiguous/static` and `ambiguous/procedural` categories.

**H2 (harm-guard):** Cell A produces similar or lower `clarification_rate` to Cell B on
`clear/dynamic` — instruction does not cause over-clarification on fully-specified tasks.

**H3 (ceiling):** The ceiling compression hypothesis (EVAL-062). If B baseline ≥ 0.900 on
ambiguous categories under the strict rubric at n=200/cell, the effect cannot be reliably
measured with this fixture and model combination regardless of n.

---

## Decision Rules (pre-registered)

### Rule 1 — RESOLVED (H1 confirmed)
**Condition:** On at least one ambiguous category (`ambiguous/static` OR
`ambiguous/procedural`), the 95% Wilson CI intervals for A and B are
**non-overlapping** (A_lower > B_upper).

**Action:** Update EVAL-050 "n=200 Results" section with RESOLVED verdict.
Update faculty map Social Cognition row to **COVERED+VALIDATED (CONFIRMED)**.

### Rule 2 — PRELIMINARY → REMOVE (ceiling structural limitation)
**Condition:** B baseline ≥ 0.850 on both ambiguous categories under strict judge at
n=200/cell, AND CIs still overlap.

**Interpretation:** Ceiling compression is structural — haiku-4-5 follows the
clarification directive but also clarifies without it at near-100% rates. The
directive's effect exists but is undetectable with this fixture and model.

**Action:**
1. Update EVAL-050 with n=200 results and ceiling-compression conclusion.
2. Update faculty map Social Cognition row to **COVERED+VALIDATED (NULL — ceiling)**
   with a note explaining what "NULL" means in this context (the behaviour
   exists; the A/B delta is too small to measure with this fixture).
3. File **EVAL-066** removal gap immediately — the PRELIMINARY label should
   not persist if the structural limitation is confirmed.

### Rule 3 — INCONCLUSIVE (unexpected result)
**Condition:** Neither Rule 1 nor Rule 2 applies (e.g., B baseline drops unexpectedly,
or CIs are very wide due to judge variance).

**Action:** Document the unexpected outcome in EVAL-050. Do NOT update the faculty
map to a definitive verdict. File a follow-up gap with a specific hypothesis for
why the result was unexpected.

---

## Statistical Test

**Primary:** Wilson 95% CI comparison (non-overlap test). This is what the harness
already computes. Non-overlapping CIs = confirmed signal at approximately p < 0.05.

**Secondary:** Two-proportion z-test on `clarification_rate` per category.
- H0: p_A = p_B
- H1: p_A > p_B (one-sided)
- α = 0.05

A/A baseline: The harness does not run an A/A cell. Judge variance is estimated
from EVAL-062's A/A implicit comparison (both cells hit near-ceiling — within ±0.05
of each other is consistent with <0.03 judge variance target from RESEARCH_INTEGRITY.md).

---

## Research Integrity Notes

Per `docs/process/RESEARCH_INTEGRITY.md`:

1. **Non-Anthropic judge:** The judge model is `claude-haiku-4-5` (Anthropic). This
   is a methodology limitation — ideally a non-Anthropic judge (e.g., Llama-3.3-70B
   via Together) would be in the panel. The strict rubric partially mitigates judge
   bias by reducing the subjectivity of the call. If results are ambiguous, a
   non-Anthropic rescore should be filed as a follow-up.

2. **Mechanism analysis:** The ceiling compression mechanism is already documented
   (EVAL-062). No new mechanism analysis required unless the result is unexpected
   (Rule 3 above).

3. **Human ground truth:** The clarification fixture is binary (did it ask or not?).
   The strict judge rubric has clear criteria. Human labeling is not required for
   this gap but would be the appropriate follow-up if the strict-judge result is
   challenged.

4. **Reproducibility:** The exact harness call is logged in this plan and will be
   repeated verbatim in EVAL-050's n=200 results section.

---

## Output Artifacts

After the sweep completes, PR-B will add:
- `docs/eval/EVAL-050-social-cognition.md` — new "n=200 Results" section with:
  - Per-category clarification rates with Wilson 95% CIs for both cells
  - Decision rule applied
  - Final verdict (RESOLVED, NULL-ceiling, or INCONCLUSIVE)
- `docs/architecture/CHUMP_FACULTY_MAP.md` — Social Cognition row updated from PRELIMINARY
  to the final verdict (no more PRELIMINARY label after this sweep)
- `EVAL-066` gap filed in `docs/gaps.yaml` if Rule 2 applies

---

## Timeline

| Step | Status |
|---|---|
| PR-A: runner + plan committed | DONE |
| Sweep kicked off (nohup) | PENDING |
| Sweep completes | PENDING (~30–60 min estimated) |
| PR-B: analysis + doc updates | PENDING |
