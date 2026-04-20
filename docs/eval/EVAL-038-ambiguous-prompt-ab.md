# EVAL-038 — Ambiguous-Prompt A/B: Social Cognition Validation of ASK_JEFF Policy

**Gap:** EVAL-038  
**Date drafted:** 2026-04-20  
**Status:** EVAL-050 run complete — see `docs/eval/EVAL-050-social-cognition.md`  
**Depends on:** EVAL-029 (neuromod task-class taxonomy — provides the harm baseline for over-asking)  
**Faculty:** Social Cognition (`src/tool_middleware.rs` ASK_JEFF flow, `CHUMP_TOOLS_ASK` env var)

> **RESEARCH INTEGRITY NOTE:** All numeric results in this document are TBD.
> Any delta reported after the run must be marked PRELIMINARY until it meets
> the standards in `docs/RESEARCH_INTEGRITY.md` (n≥50 per cell, non-Anthropic
> judge in panel, A/A baseline within ±0.03). Do not cite any result from
> this eval as "validated" before those conditions are satisfied.

---

## Hypothesis

**H1 (primary):** Ask-first (Cell A) produces a higher intent-match rate than
guess-and-act (Cell B) on `ambiguous/static` and `ambiguous/procedural` prompts,
where the correct action cannot be determined from the prompt text alone.

**H2 (harm guard):** Ask-first (Cell A) produces a *lower* intent-match rate than
Cell B on `clear/dynamic` prompts — confirming the EVAL-029 finding that prompts
with an explicit conditional chain (or here, a fully-specified task) are harmed by
adding a clarification step.

**Combined policy claim (pending H1 + H2):** If H1 and H2 both hold directionally
at n≥50 per cell and the effect sizes are distinguishable, this would support
scoping the ASK_JEFF policy to genuinely ambiguous prompts — and suppressing it on
`clear/dynamic` prompts. This is consistent with the EVAL-030 task-class-aware
gating approach already applied to the lessons block.

---

## Fixture Summary

**File:** `docs/eval/EVAL-038-ambiguous-prompt-fixture.yaml`  
**Total prompts:** 30  
**Category breakdown:**

| Category | Count | Expected clarification need |
|---|---|---|
| `ambiguous/static` | 10 | true (prompts 01-10) |
| `ambiguous/procedural` | 10 | true (prompts 11-20) |
| `clear/dynamic` | 10 | false (prompts 21-30) |

**Task types covered:** coding (fix, refactor), debugging (bug, test), documentation,
configuration, performance optimisation, read-only queries, filesystem checks.

**Ground truth:** established at fixture-authoring time as the most plausible single
developer intent for each prompt. For ambiguous categories the ground truth is "agent
should ask before acting." For clear/dynamic the ground truth is "agent should act
immediately without asking."

---

## Methodology

### Two cells

| Cell | System prompt modification | Behaviour expected |
|---|---|---|
| **A (ASK-FIRST)** | Prepend the COG-016 lessons block, which includes the directive: "If the user prompt is ambiguous (e.g. lacks a target path, file, or scope), ask one clarifying question rather than guessing." | Agent asks for clarification on ambiguous prompts; acts on clear ones. |
| **B (GUESS-AND-ACT)** | No lessons block — baseline prompt assembler output only. | Agent infers intent and acts immediately on all prompts. |

Cell A is the current production-default for sessions where lessons injection is
enabled. Cell B is the baseline.

### Judge rubric

Each trial is scored by the LLM judge against the per-fixture `judge_rubric` field.
The rubric for ambiguous prompts rewards asking (1.0 = clarified before acting, 0.0 =
acted without clarifying). The rubric for clear prompts rewards immediate action
(1.0 = acted without asking, 0.0 = asked before acting).

**Judge composition (required by RESEARCH_INTEGRITY.md):**
- Primary: `claude-sonnet-4-5` (Anthropic)
- Cross-family: `together:meta-llama/Llama-3.3-70B-Instruct-Turbo` (non-Anthropic, free tier)
- Panel verdict: median of the two scores rounded to nearest 0.5

Single-judge runs with Anthropic-only judges are preliminary only and must not be
cited as findings.

### Scoring axes (per trial)

Following the multi-axis scoring in `run-cloud-v2.py`:

| Axis | What it measures |
|---|---|
| `did_ask` | Did the agent produce a clarifying question in its response? (binary, extracted by regex) |
| `did_act_first` | Did the agent make a code edit or tool call before asking? (binary) |
| `intent_match` | Does the eventual action (or stated plan) match `ground_truth_action`? (LLM judge 0.0–1.0) |

Primary outcome metric: `intent_match`. Secondary: `did_ask` rate per category to
confirm the cells are behaving as intended.

### Required sample size and A/A baseline

Per `docs/RESEARCH_INTEGRITY.md`:
- Minimum n=50 per cell per category for directional signal
- n=100 per cell for ship-or-cut decisions
- A/A baseline run required before citing deltas (A/A delta must be within ±0.03)

**For this eval:** run A/A first (both cells use the lessons block) on the 10
`clear/dynamic` prompts to establish the noise floor. Then run the full A/B.

---

## Exact harness command (placeholder — requires CHUMP_EXPERIMENT_CHECKPOINT)

> **Note:** Replace `<CHECKPOINT_TAG>` with the value of `CHUMP_EXPERIMENT_CHECKPOINT`
> from the environment at run time (required for reproducibility per
> `docs/RESEARCH_INTEGRITY.md` standard 6). The checkpoint tag locks the chump
> binary version, model endpoint, and lessons block content so the run can be
> reproduced identically.

### Step 1 — A/A baseline (noise floor on clear/dynamic prompts)

```bash
CHUMP_EXPERIMENT_CHECKPOINT=<CHECKPOINT_TAG> \
python3 scripts/ab-harness/run-cloud-v2.py \
    --fixture docs/eval/EVAL-038-ambiguous-prompt-fixture.yaml \
    --fixture-filter "category=clear/dynamic" \
    --tag eval038-aa-clear-$(date +%s) \
    --mode aa \
    --model claude-haiku-4-5 \
    --judge claude-sonnet-4-5,together:meta-llama/Llama-3.3-70B-Instruct-Turbo \
    --lessons-version cog016 \
    --limit 10
```

Expected A/A delta: within ±0.03. If exceeded, do not proceed to A/B until
judge variance is understood.

### Step 2 — Full A/B sweep (all 30 prompts, n≥50 per cell)

```bash
CHUMP_EXPERIMENT_CHECKPOINT=<CHECKPOINT_TAG> \
python3 scripts/ab-harness/run-cloud-v2.py \
    --fixture docs/eval/EVAL-038-ambiguous-prompt-fixture.yaml \
    --tag eval038-ab-full-$(date +%s) \
    --mode ab \
    --model claude-haiku-4-5 \
    --judge claude-sonnet-4-5,together:meta-llama/Llama-3.3-70B-Instruct-Turbo \
    --lessons-version cog016 \
    --n 50
```

### Step 3 — Score and append result

```bash
python3 scripts/ab-harness/score.py \
    logs/ab/eval038-ab-full-<TIMESTAMP>.jsonl \
    docs/eval/EVAL-038-ambiguous-prompt-fixture.yaml

scripts/ab-harness/append-result.sh \
    logs/ab/eval038-ab-full-<TIMESTAMP>.summary.json \
    EVAL-038 \
    --note "haiku-4-5 ASK vs GUESS; judge panel: sonnet-4-5 + llama-3.3-70b"
```

---

## Expected result shape

If H1 and H2 both hold:

| Category | Cell A intent_match | Cell B intent_match | Expected Δ (A−B) |
|---|---|---|---|
| ambiguous/static | higher | lower | positive |
| ambiguous/procedural | higher | lower | positive |
| clear/dynamic | lower | higher | **negative** (Cell A over-asks) |

The key finding would be the sign flip between ambiguous and clear categories —
the same ask-first policy that helps on ambiguous prompts hurts on clear ones.
This mirrors the EVAL-029 neuromod finding (conditional-chain dilution) and would
provide the first Social Cognition faculty A/B evidence.

---

## Failure modes and interpretations

| Observation | Interpretation | Next action |
|---|---|---|
| Δ ≈ 0 on ambiguous categories | Agent guesses correctly on ambiguous prompts (LLM intent inference is strong) | Lower sample size doesn't give signal — run n=100 before concluding |
| Δ ≈ 0 on clear/dynamic | Ask-first doesn't hurt clear prompts either | Harmless policy; broader deployment may be safe |
| A/A delta > ±0.03 | Judge variance is too high for this fixture | Switch to human labeling for this eval; file EVAL-041 follow-up |
| Cell A never asks on ambiguous prompts | Lessons block directive is not activated by these prompts | Inspect system prompt construction; file a lessons-directive gap |
| Cell B consistently matches ground truth on ambiguous prompts | Model intent inference is strong without asking | Policy might be unnecessary overhead; document and defer |

---

## Results (TBD — run not yet executed)

> **PRELIMINARY PLACEHOLDER.** The following section will be populated after
> the harness run completes. All values below are TBD. Do not cite this section
> until it is populated with actual run output and marked as meeting the
> RESEARCH_INTEGRITY.md standards.

### A/A baseline

| Metric | Run 1 | Run 2 | Δ | Noise floor acceptable? |
|---|---|---|---|---|
| clear/dynamic intent_match | TBD | TBD | TBD | TBD |

### A/B per-category intent_match rates

| Category | n per cell | Cell A | Cell B | Δ (A−B) | 95% CI overlap? | Directional signal? |
|---|---|---|---|---|---|---|
| ambiguous/static | TBD | TBD | TBD | TBD | TBD | TBD |
| ambiguous/procedural | TBD | TBD | TBD | TBD | TBD | TBD |
| clear/dynamic | TBD | TBD | TBD | TBD | TBD | TBD |

### did_ask rate by cell and category (manipulation check)

| Category | Cell A did_ask | Cell B did_ask |
|---|---|---|
| ambiguous/static | TBD | TBD |
| ambiguous/procedural | TBD | TBD |
| clear/dynamic | TBD | TBD |

### Harness call log

```
CHUMP_EXPERIMENT_CHECKPOINT=TBD
run timestamp: TBD
model: TBD
judge: TBD
```

### Policy recommendation (to be filled after results)

TBD — will state whether EVAL-038 supports narrowing ASK_JEFF to ambiguous
prompts only, or whether the current undifferentiated policy is acceptable.

---

## Connections to other gaps and findings

- **EVAL-029** — established the "conditional-chain dilution" harm for lessons
  on dynamic prompts. EVAL-038 extends the same taxonomy to the ask-first
  directive specifically.
- **EVAL-030** — shipped task-class-aware gating for the lessons block. If
  EVAL-038 confirms ask-first harm on clear prompts, a parallel task-class
  gate for the clarification directive is the natural follow-on.
- **RESEARCH_INTEGRITY.md** — Social Cognition currently has no A/B evidence.
  EVAL-038 is the first eval to produce a numeric signal for this faculty.

---

## Sources

- Fixture: `docs/eval/EVAL-038-ambiguous-prompt-fixture.yaml`
- Harness: `scripts/ab-harness/run-cloud-v2.py`
- Prior task taxonomy: `docs/eval/EVAL-029-neuromod-task-drilldown.md`
- Faculty map: `docs/CHUMP_FACULTY_MAP.md` (Social Cognition row)
- Research standards: `docs/RESEARCH_INTEGRITY.md`
