# Preregistration — `EVAL-101`

> **Status:** LOCKED at commit `<SHA-filled-at-commit-time>`. Do not edit
> locked fields after data collection begins — add a Deviations entry instead.

## 1. Gap reference

- **Gap ID:** `EVAL-101`
- **Gap title:** CREDIBLE: cognition A/B with fleet evidence — does the cognition stack (reflections, lessons, neuromodulation) improve agent task outcomes?
- **Source critique:** COG-041 (semantic ranking), COG-046 (embeddings), COG-011 (reflection injection), COG-006 (neuromodulation), COG-024 (lesson pipeline) all shipped on faith. EVAL-098 verified semantic ranking diverges from recency-frequency but didn't measure quality. This eval measures whether the combined cognition stack actually improves task success.
- **Author:** `opencode-2026-05-10`
- **Preregistration date:** 2026-05-10

## 2. Hypothesis

**Primary hypothesis (H1):**
> If the cognition stack (reflection injection + neuromodulation + semantic lesson retrieval) is enabled, then structural task-completion score will increase by at least 0.10 (on a 0-1 scale) relative to the no-cognition baseline.

**Null hypothesis (H0):**
> The cognition stack produces no measurable improvement in task-completion score (mean delta ≤ 0.03, CI overlaps zero).

**Alternative explanations to rule out:**
- *Prompt-length confound* — cognition stack adds ~500 tokens of context; any improvement could be from longer prompts, not content. Addressed by Cell C (neutral-padding control).
- *Single-fixture bias* — reflection tasks may play to the stack's strengths while other task types wouldn't. Addressed by using the reflection fixture (standard benchmark) but reporting per-task-type subgroups.

## 3. Design

### Cells
| Cell | Intervention | Expected direction |
|---|---|---|
| A | cognition stack OFF (CHUMP_REFLECTION_INJECTION=0, CHUMP_NEUROMOD_ENABLED=0, CHUMP_LESSONS_SEMANTIC=0) | baseline |
| B | cognition stack ON (all flags enabled, current defaults after COG-041/046 ship) | + ≥0.10 vs A |
| C | neutral padding control: add 500 tokens of whitespace/irrelevant text to Cell A prompt | ≈ A (to rule out length confound) |

### Sample size
- **n per cell:** 20 tasks (from reflection_tasks.json fixture). Total: 60 trials.
- **Power analysis:** to detect Δ=0.10 at α=0.05 with power=0.80 on a paired binary outcome with expected baseline 0.55 (from COG-011 run), n≥19 per cell. Using n=20.
- **Fixtures used:** `scripts/ab-harness/fixtures/reflection_tasks.json` (standard 20-task reflection benchmark)

### Model & provider matrix
| Role | Model(s) | Provider | Endpoint |
|---|---|---|---|
| Agent under test | claude-sonnet-4-20250514 | Anthropic API | default |
| LLM judge | claude-haiku-3-5-20241022 | Anthropic API | default |
| LLM judge (cross-family) | gpt-4o-mini | OpenAI | default |

### Randomization & order
- Trial order: deterministic A→B→C per task (same task seen in all 3 modes consecutively).
- Task order: as-is from fixture (fixed seed across all 3 runs).
- Each trial uses a fresh agent session (no cross-trial state).

## 4. Primary metric

**Task-completion score** — structural property check from `src/eval_harness.rs::check_property`, reimplemented in `scripts/ab-harness/score.py`.

```
score_per_task = (passed_checks / total_checks)  for the task's structural properties
cell_mean = mean(score_per_task) across all tasks in that cell
delta = cell_mean(B) - cell_mean(A)
```

**Reporting format:** point estimate + Wilson 95% CI + A/A noise floor from a separate A/A run (Cell A vs Cell A' on a 10-task subset).

## 5. Secondary metrics

- **Tool-call efficiency** — mean tool-calls per task (fewer is better for the same score).
- **Hallucinated-tool-call rate** — tool calls with invalid arguments (per EVAL-041 regex).
- **Mean response length** — characters per final response.
- **Judge inter-rater kappa** — agreement between haiku and gpt-4o-mini judges on a 10-task overlap subset.

## 6. Stopping rule

**Planned n:** 20 per cell (60 total).

**Early stop allowed?** No. All 60 trials must complete for the preregistered analysis.

**Exhaustion stop:** If API budget or rate limits prevent completing n=20/cell within 24h wall-clock, report partial result with explicit "underpowered" label and document how many trials completed per cell.

## 7. Analysis plan

**Primary analysis (preregistered):**
1. Compute task-completion score per trial.
2. Compute cell means with Wilson 95% CIs.
3. Compute delta B−A with bootstrapped CI (10,000 resamples).
4. Test H1: delta B−A CI lower bound > 0.10.
5. Cell C vs A: CI should overlap zero (confirming length isn't the driver).
6. Report against A/A noise floor: delta must be ≥3× the A/A stdev to be interpretable.

**Secondary analyses (also preregistered):**
- Per-task-type subgroup analysis (coding tasks vs reasoning tasks vs writing tasks).
- Per-judge agreement (Cohen's kappa between haiku and gpt-4o-mini).
- Tool-call efficiency comparison (B vs A, Mann-Whitney U).

**Exploratory analyses (allowed but clearly labeled):**
- Per-question qualitative review of largest-delta and smallest-delta tasks.
- Correlation between reflection count and score improvement.
- Analysis of "regression" cases where A outscored B.

## 8. Exclusion rules

A trial is excluded from analysis iff:
- Agent response was empty (0 bytes).
- Judge call returned HTTP error or timeout.
- Provider returned a 5xx error during the trial.
- Task fixture was missing required fields (id, query, checks).

All exclusions must be logged with reason. Exclusion rate >10% invalidates the sweep.

## 9. Decision rule

**If H1 supported** (B−A CI lower bound > 0.10, delta ≥3× A/A noise floor):
- Ship to FINDINGS: "Cognition stack improves task outcomes by Δ=X [CI: Y-Z]."
- Recommend flipping all cognition flags ON by default across the fleet.
- Close EVAL-101 as evidence-supported.

**If H1 rejected** (CI overlaps zero or delta < 0.10):
- Ship as null result: "Cognition stack does not measurably improve outcomes on this fixture."
- Recommend audit: is the stack not working, or is the fixture not sensitive enough?
- File follow-up gap for fixture redesign or per-component ablation.

**If ambiguous** (CI wide, overlaps zero but mean in predicted direction >0.05):
- Escalate to n=50/cell.
- File EVAL-102 for the power-increase run with preregistered sequential analysis.

## 10. Budget

- **Cloud cost:** ~$3 for agent calls (60 trials × ~$0.05/trial with sonnet) + ~$1 for judge calls = ~$4 total.
- **Wall-clock:** ~2-4 hours (60 trials × ~2-4 min/trial).
- **Human time:** 0h (fully automated scoring).

## 11. Risks & mitigations

| Risk | Mitigation |
|---|---|
| Judge disagreement inflates metric noise | Use 2 judges (haiku + gpt-4o-mini); report both; primary uses haiku |
| Fixture tasks are too easy (ceiling effect) | Pre-check: if Cell A mean > 0.90, flag as ceiling and consider harder fixture |
| Ollama not running (cell C padding fails) | Padding is text-based, not LLM-based; no Ollama needed |
| Sibling session touches same state.db | Run all 60 trials in one shot; no interleaved state changes |

---

## Deviations (append-only, timestamped)

### [2026-05-10] D-1: Agent substituted — Qwen 2.5 14B instead of claude-sonnet-4-20250514

- **Preregistered agent:** `claude-sonnet-4-20250514` (Anthropic API)
- **Actual agent:** `Qwen 2.5 14B` via Ollama local endpoint
- **Cause:** Anthropic API key unavailable at run time; operator did not update the preregistration or halt the sweep.
- **Impact:** Results are not interpretable as evidence about the intended model. Different architecture, different base rates, different instruction-following behaviour. Null result (Δ=+0.025) cannot be attributed to the cognition stack on the intended model.
- **Disposition:** Results NOT valid for H1/H0 on claude-sonnet-4. Marked as protocol violation. EVAL-102 filed for correct re-run.

### [2026-05-10] D-2: Sample size below RESEARCH_INTEGRITY floor — n=20/cell (required n≥50)

- **Preregistered floor:** n≥50 per cell (RESEARCH_INTEGRITY.md §1)
- **Actual n:** 20 per cell (power-analysis minimum only; below the required floor)
- **Impact:** Results are underpowered independent of the model substitution.
- **Disposition:** Directional signal unreliable. EVAL-102 specifies n=50 per cell.

### [2026-05-10] D-3: Cell C (neutral-padding control) skipped

- **Preregistered:** Cell C required to rule out prompt-length confound (§3 Design).
- **Actual:** Cell C omitted. Reason logged: "Ollama timeout, skipping C."
- **Impact:** Prompt-length confound cannot be ruled out. Any observed Δ could be length artefact.
- **Disposition:** Results not interpretable as a clean A/B comparison. Cell C is mandatory in EVAL-102.

### [2026-05-10] D-4: No LLM judge — structural scoring only

- **Preregistered judges:** dual LLM (claude-haiku-3-5-20241022 + gpt-4o-mini, §3 Model matrix)
- **Actual:** Structural property scoring only (`scripts/ab-harness/score.py`); no LLM calls.
- **Impact:** Structural scoring cannot capture partial credit or semantic correctness. RESEARCH_INTEGRITY.md §6 requires at least one LLM judge for EVAL-* runs.
- **Disposition:** Scoring is incomparable to the preregistered protocol. EVAL-102 requires dual judges including a non-Anthropic family.

---

**Summary:** All four deviations together mean EVAL-101 results are non-interpretable as evidence for or against H1. The null result (Δ=+0.025, p≈0.4) should be treated as a failed protocol execution, not a scientific finding. EVAL-102 is the registered re-run with corrected protocol.
