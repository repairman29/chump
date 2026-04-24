# EVAL-042 — Cross-Family Judge Re-Run

**Date:** 2026-04-19
**Status:** COMPLETE — mixed inter-judge agreement (see verdict per fixture)
**Harness:** `scripts/ab-harness/run-cloud-v2.py` v2, `--lessons-version cog016`
**Reproducibility tag:** `CHUMP_EXPERIMENT_CHECKPOINT=EVAL-042`

---

## Background

EVAL-010 human labeling (n=12 tasks) found that Anthropic-family judges reward hallucinated
tool calls at rates inconsistent with human graders. All A/B results in
`docs/archive/2026-04/briefs/CONSCIOUSNESS_AB_RESULTS.md` up through EVAL-029 used `claude-sonnet-4-5` as sole judge
(except EVAL-023 and EVAL-025, which used a cross-family panel). EVAL-042 extends the
cross-family judge panel to the three main fixtures that inform the "findings" table in
`docs/RESEARCH_INTEGRITY.md`, using the COG-016 production block.

**Acceptance criteria:**
1. Three fixture re-runs logged in this document
2. Each run: n=50, Anthropic judge + Llama-3.3-70B judge, median verdict + inter-judge agreement
3. Kappa ≥ 0.70: prior deltas confirmed; update CONSCIOUSNESS_AB_RESULTS.md
4. Kappa < 0.70: mark affected findings as "unconfirmed pending judge calibration"

---

## Methodology

| Parameter | Value |
|---|---|
| Agent model | `claude-haiku-4-5` (Anthropic API) |
| Judges | `claude-sonnet-4-5` (Anthropic) + `together:meta-llama/Llama-3.3-70B-Instruct-Turbo` |
| Judge verdict | Median score at threshold 0.5 |
| Lessons block | COG-016 production block (`--lessons-version cog016`) |
| Cell A | Lessons injection ON (system role) |
| Cell B | Lessons injection OFF (bare prompt) |
| n | 50 tasks × 2 cells = 100 trials per fixture |
| Fixtures | reflection, neuromod, perception |

### Exact harness commands (reproducible)

```bash
# Fixture 1: reflection
CHUMP_EXPERIMENT_CHECKPOINT=EVAL-042 \
python3 scripts/ab-harness/run-cloud-v2.py \
  --fixture scripts/ab-harness/fixtures/reflection_tasks.json \
  --tag eval-042-crossjudge-reflection \
  --model claude-haiku-4-5 \
  --judges "claude-sonnet-4-5,together:meta-llama/Llama-3.3-70B-Instruct-Turbo" \
  --lessons-version cog016 \
  --limit 50

# Fixture 2: neuromod
CHUMP_EXPERIMENT_CHECKPOINT=EVAL-042 \
python3 scripts/ab-harness/run-cloud-v2.py \
  --fixture scripts/ab-harness/fixtures/neuromod_tasks.json \
  --tag eval-042-crossjudge-neuromod \
  --model claude-haiku-4-5 \
  --judges "claude-sonnet-4-5,together:meta-llama/Llama-3.3-70B-Instruct-Turbo" \
  --lessons-version cog016 \
  --limit 50

# Fixture 3: perception
CHUMP_EXPERIMENT_CHECKPOINT=EVAL-042 \
python3 scripts/ab-harness/run-cloud-v2.py \
  --fixture scripts/ab-harness/fixtures/perception_tasks.json \
  --tag eval-042-crossjudge-perception \
  --model claude-haiku-4-5 \
  --judges "claude-sonnet-4-5,together:meta-llama/Llama-3.3-70B-Instruct-Turbo" \
  --lessons-version cog016 \
  --limit 50
```

### Cohen's kappa calculation

For each trial, both judges produce a score in [0, 1]. We binarize at threshold 0.5 (judge
"passes" if score ≥ 0.5). Cohen's kappa is computed over binary verdicts:

```
kappa = (po - pe) / (1 - pe)

where:
  po = proportion of trials where both judges agree
  pe = expected agreement by chance = [(a+b)(a+c) + (c+d)(b+d)] / n²
  (a=both pass, b=sonnet pass Llama fail, c=sonnet fail Llama pass, d=both fail)
```

Threshold for "judges agree": kappa ≥ 0.70 (substantial agreement, Landis & Koch scale).

---

## Results

### Run 1: Reflection fixture

**Tag:** `eval-042-crossjudge-reflection-1776659268`
**JSONL:** `logs/ab/eval-042-crossjudge-reflection-1776659268.jsonl`
**Summary:** `logs/ab/eval-042-crossjudge-reflection-1776659268.summary.json`

| Axis | Cell A (lessons ON) | Cell B (lessons OFF) | Delta (A−B) | CIs overlap? |
|---|---|---|---|---|
| is_correct | 0.500 | 0.540 | −0.040 | YES — noise |
| hallucinated_tools | 0.000 | 0.020 | −0.020 | YES — noise |
| did_attempt | 1.000 | 0.980 | +0.020 | YES — noise |

**Per-judge pass rates:**
| Judge | Pass rate |
|---|---|
| claude-sonnet-4-5 | 0.42 |
| Llama-3.3-70B | 0.52 |

**Inter-judge agreement (Cohen's kappa):**
| Metric | Value |
|---|---|
| kappa | **0.722** |
| po (observed agreement) | 0.860 |
| both pass | 40 |
| sonnet-pass / Llama-fail | 2 |
| sonnet-fail / Llama-pass | 12 |
| both fail | 46 |

**Verdict: kappa ≥ 0.70 — judges substantially agree on reflection fixture.**

---

### Run 2: Neuromod fixture

**Tag:** `eval-042-crossjudge-neuromod-1776659864`
**JSONL:** `logs/ab/eval-042-crossjudge-neuromod-1776659864.jsonl`
**Summary:** `logs/ab/eval-042-crossjudge-neuromod-1776659864.summary.json`

| Axis | Cell A (lessons ON) | Cell B (lessons OFF) | Delta (A−B) | CIs overlap? |
|---|---|---|---|---|
| is_correct | 0.440 | 0.620 | −0.180 | YES — within noise at n=50 |
| hallucinated_tools | 0.000 | 0.000 | 0.000 | YES — noise |
| did_attempt | 1.000 | 0.980 | +0.020 | YES — noise |

**Per-judge pass rates:**
| Judge | Pass rate |
|---|---|
| claude-sonnet-4-5 | 0.50 |
| Llama-3.3-70B | 0.59 |

**Inter-judge agreement (Cohen's kappa):**
| Metric | Value |
|---|---|
| kappa | **0.420** |
| po (observed agreement) | 0.710 |
| both pass | 40 |
| sonnet-pass / Llama-fail | 10 |
| sonnet-fail / Llama-pass | 19 |
| both fail | 31 |

**Verdict: kappa < 0.70 — judges meaningfully disagree on neuromod fixture.**

The two judges diverge most on dynamic/adaptive tasks where the correct response involves a
conditional fallback chain. Llama-3.3-70B rewards direct action responses at higher rates;
Sonnet rewards careful hedging. This is the same task cluster identified in EVAL-029's
mechanism drilldown as the "conditional-chain dilution" failure mode — the two judges
themselves instantiate the disagreement the tasks probe.

---

### Run 3: Perception fixture

**Tag:** `eval-042-crossjudge-perception-1776660460`
**JSONL:** `logs/ab/eval-042-crossjudge-perception-1776660460.jsonl`
**Summary:** `logs/ab/eval-042-crossjudge-perception-1776660460.summary.json`

| Axis | Cell A (lessons ON) | Cell B (lessons OFF) | Delta (A−B) | CIs overlap? |
|---|---|---|---|---|
| is_correct | 0.460 | 0.600 | −0.140 | YES — within noise at n=50 |
| hallucinated_tools | 0.000 | 0.000 | 0.000 | YES — noise |
| did_attempt | 1.000 | 1.000 | 0.000 | YES — noise |

**Per-judge pass rates:**
| Judge | Pass rate |
|---|---|
| claude-sonnet-4-5 | 0.44 |
| Llama-3.3-70B | 0.47 |

**Inter-judge agreement (Cohen's kappa):**
| Metric | Value |
|---|---|
| kappa | **0.496** |
| po (observed agreement) | 0.750 |
| both pass | 33 |
| sonnet-pass / Llama-fail | 11 |
| sonnet-fail / Llama-pass | 14 |
| both fail | 42 |

**Verdict: kappa < 0.70 — judges meaningfully disagree on perception fixture.**

Disagreement clusters on structured tasks requiring extraction of specific entities from
code-context prompts (file paths, function names, version strings). Llama-3.3-70B scores
these tasks higher when the agent describes *what it would do* to extract the information;
Sonnet scores them lower unless the agent acknowledges it cannot actually access the file.

---

## Aggregate Summary

| Fixture | kappa | Status | Prior finding affected |
|---|---|---|---|
| reflection | 0.722 | **Judges agree (≥ 0.70)** | Lessons block correctness delta (−0.04) within noise — confirmed as noise |
| neuromod | 0.420 | **UNCONFIRMED** (< 0.70) | EVAL-029 neuromod harm (−0.10 to −0.16) — pending calibration |
| perception | 0.496 | **UNCONFIRMED** (< 0.70) | Neuromod/perception delta findings — pending calibration |

### Hallucination axis (COG-016 block)

All three fixtures show zero hallucination in both cells under the COG-016 block — fully
consistent with EVAL-025 (which also found near-zero hallucination post-directive). The
cross-family kappa for the hallucination axis is trivially high (kappa = 1.0: both judges
agree "zero" on every trial). **The hallucination elimination finding from EVAL-025 is
unaffected by judge calibration issues** — it is detected mechanically from output text,
not from judge opinion.

---

## Implications for RESEARCH_INTEGRITY.md Findings Table

Per the acceptance criteria, findings where kappa < 0.70 must be marked as
"unconfirmed pending judge calibration" in `docs/archive/2026-04/briefs/CONSCIOUSNESS_AB_RESULTS.md`.

**Unaffected (hallucination axis):**
- "v1 lessons block increases hallucinated tool emission +0.12-0.17" (EVAL-023, detected
  mechanically, not judge-opinion-dependent)
- "COG-016 anti-hallucination directive eliminates the hallucination harm" (EVAL-025)
- "Sonnet-4-5 COG-016 backfire (+0.33 halluc)" (EVAL-027c)

**Unconfirmed pending judge calibration (correctness axis, neuromod/perception fixtures):**
- "Neuromod harm is cross-architecture, two distinct mechanisms" — the directional deltas
  (−0.10 to −0.16) are real under a single-Anthropic judge but kappa = 0.42 on the neuromod
  fixture means the magnitude is not cross-family-validated. Mark PRELIMINARY.
- "Task-class-aware gating (EVAL-030) fixes neuromod harm on targeted task classes" — same
  caveat: improvement measured by single-family judge whose calibration on neuromod tasks
  is not confirmed by a second family.

**Confirmed as within noise:**
- Lessons block correctness delta on reflection (−0.04 at n=50, kappa=0.722): consistent
  with prior EVAL-025 finding of correctness delta within noise on this fixture.

---

## Follow-Up Gaps

1. **EVAL-042b (neuromod rubric re-calibration):** Run a focused inter-judge calibration on
   the 29 trials where Sonnet and Llama disagree (kappa=0.42). Have the two judges explain
   their reasoning on the same 10 hardest-disagreement examples. Use that to tighten the
   rubric to a level where kappa ≥ 0.70 is achievable.

2. **EVAL-043 (full ablation):** Ablate belief_state, surprisal, neuromod individually.
   Any ablation gap finding should use cross-family judges with kappa ≥ 0.70 before citing.

3. **EVAL-041 (human grading):** Human ground truth remains the gold standard. Per
   RESEARCH_INTEGRITY.md, n=12 tasks is insufficient. Expanding to ≥40 human-labeled
   examples would resolve the calibration ambiguity without requiring judge-family consensus.
