# Preregistration — `EVAL-102` (EVAL-101 re-run)

> **Status:** LOCKED at commit `<SHA-filled-at-commit-time>`. Do not edit
> locked fields after data collection begins — add a Deviations entry instead.

## 0. Why this exists

EVAL-101 was filed as the canonical A/B test of the cognition stack
(reflections, lessons, neuromodulation) and closed as null result
(Δ=+0.025) on 2026-05-10. The cold-water audit
([INFRA-824](../../gaps/INFRA-824.yaml), PR
[#1449](https://github.com/repairman29/chump/pull/1449)) documented that
the actual run violated multiple [`RESEARCH_INTEGRITY.md`](../../process/RESEARCH_INTEGRITY.md)
requirements and the preregistration itself:

- **Agent**: ran Qwen 2.5 14b (local Ollama) instead of preregistered `claude-sonnet-4-20250514`
- **n per cell**: 20 (RESEARCH_INTEGRITY §1 requires ≥50 for directional, ≥100 for ship-decisions; the original prereg was already underpowered at 20)
- **Cell C** (neutral-padding control): omitted, "due to Ollama timeout"
- **Judges**: structural scoring only — no LLM judges despite preregistration requiring haiku + gpt-4o-mini, and RESEARCH_INTEGRITY §2 requiring at least one non-Anthropic judge
- **Deviations section**: blank, despite all of the above

The null result cannot be cited as evidence the cognition stack fails,
nor that it succeeds. The cognition stack remains faith-based until this
re-run completes.

This preregistration corrects every deviation and adds runtime
enforcement so the same drift cannot recur.

## 1. Gap reference

- **Gap ID:** `EVAL-102`
- **Replaces:** `EVAL-101` (closed as null; result not citable)
- **Audit trail:** [INFRA-824](../../gaps/INFRA-824.yaml) cold-water audit, [#1449](https://github.com/repairman29/chump/pull/1449)
- **Author:** opus-4-7 (operator-delegated design per META-046)
- **Preregistration date:** 2026-05-11
- **Status:** locked-pending-commit

## 2. Hypothesis

**Primary hypothesis (H1):**
> When the cognition stack (CHUMP_REFLECTION_INJECTION=1 + CHUMP_NEUROMOD_ENABLED=1 + CHUMP_LESSONS_SEMANTIC=1 + CHUMP_LESSONS_AT_SPAWN_N=5) is enabled, structural task-completion score increases by at least 0.08 (on 0-1) relative to all flags off, with the lower bound of the Wilson 95% CI on the delta strictly above zero.

**Null hypothesis (H0):**
> Mean delta ≤ 0.03 OR Wilson 95% CI on the delta crosses zero.

**Alternatives to rule out:**
- *Prompt-length confound* — the stack adds ~500 tokens of context. Cell C (neutral-padding control) addresses this.
- *Judge artifact* — a single judge could be systematically biased toward the cognition-stack output style. Two-judge panel with one non-Anthropic judge addresses this.
- *Single-fixture bias* — addressed by subgroup reporting on the reflection-tasks fixture's intrinsic task-type axis.
- *Model-family generalization* — addressed by running the full protocol on Sonnet AND a smaller secondary run on Haiku to confirm direction is consistent.

## 3. Design

### Cells
| Cell | Intervention | Expected direction |
|---|---|---|
| A | cognition stack OFF (CHUMP_REFLECTION_INJECTION=0, CHUMP_NEUROMOD_ENABLED=0, CHUMP_LESSONS_SEMANTIC=0, CHUMP_LESSONS_AT_SPAWN_N=0) | baseline |
| B | cognition stack ON (all flags enabled, current defaults) | + ≥0.08 vs A |
| C | neutral padding control: Cell A prompt + 500 tokens of structurally-irrelevant filler in domain language so it's not obviously distinguishable from cognition content by surface features | ≈ A (rules out length confound) |
| A' | Cell A repeated against same fixture (different seed offset) | A/A noise floor |

### Sample size
- **n per cell:** 50 (primary, directional signal per RESEARCH_INTEGRITY §1)
- **Total trials:** 50 × 4 cells = 200 on primary agent
- **Secondary (Haiku confirmatory):** 25 × 3 cells (A/B/C) = 75, run only after primary completes; powered for directional confirmation only
- **Power analysis:** to detect Δ=0.08 at α=0.05 with power=0.80 on a paired binary outcome with expected baseline 0.55, n≥48 per cell. Using n=50.
- **Underpowered abort:** if A/A noise floor exceeds ±0.05 on the 10-task overlap subset, abort and re-baseline before continuing.
- **Fixture:** `scripts/ab-harness/fixtures/reflection_tasks.json` — used 2.5× to reach n=50; randomized order per trial-set.

### Model & provider matrix (LOCKED)
| Role | Model | Provider | Endpoint | Why |
|---|---|---|---|---|
| **Primary agent** | claude-sonnet-4-6 | Anthropic API | default | Current production fleet default |
| **Confirmatory agent** | claude-haiku-4-5 | Anthropic API | default | Cost-efficient direction confirmation |
| **LLM judge #1** | claude-haiku-4-5 | Anthropic API | default | In-family judge |
| **LLM judge #2** | meta-llama/Llama-3.3-70B-Instruct | Together AI (free tier $0) | default | Non-Anthropic judge per RESEARCH_INTEGRITY §2 |

**Explicitly prohibited (would invalidate the run):**
- Substituting any local Ollama model (Qwen / Llama-cpp / etc.) for the primary agent — this is exactly what invalidated EVAL-101
- Anthropic-only judge panel
- `--scorer exit-code` as a primary scorer (per RESEARCH_INTEGRITY §6)

### Randomization & order
- **Trial order:** within each cell, tasks in fixture-order (deterministic; fixed seed); cells interleaved A-B-C-A' per task to minimize cross-cell drift in API latency / quota state
- **Each trial:** fresh agent session, no cross-trial state
- **Judges:** scored after all 200 primary trials complete, on shuffled order to blind judges to cell

## 4. Primary metric

**Composite task-completion score**, equal-weight average of:
1. **Structural score** — `scripts/ab-harness/score.py` against fixture's structural properties (0-1)
2. **Judge consensus score** — average of the 2 LLM judges' strict-binary rubric (0 or 1 per judge, averaged)

```
score_per_task = 0.5 * structural + 0.5 * mean(judge1_binary, judge2_binary)
cell_mean = mean(score_per_task) across the 50 tasks
delta = cell_mean(B) - cell_mean(A)
```

**Reporting format:** point estimate + Wilson 95% CI on delta + A/A noise floor from Cell A vs Cell A' on the full 50-task overlap.

## 5. Secondary metrics

- **Tool-call efficiency** — mean tool-calls per task
- **Hallucinated-tool-call rate** — invalid-arguments tool calls (per EVAL-041 regex)
- **Mean response length** — characters per final response (sanity-check the padding-cell didn't drift response length)
- **Judge inter-rater kappa** — agreement between the two judges across the 50-task overlap; report per cell
- **Per-task-type subgroup** — score deltas split by fixture's task-type axis

## 6. Stopping rule

**Planned n:** 50 per cell × 4 cells = 200 trials primary. NO early stop.

**Exhaustion stop:** if API budget or rate limits prevent completing n=50 per cell within 48h wall-clock, report partial result with **"underpowered"** label and **do not draw directional conclusions** — the run is treated as a re-baseline only.

**Hard abort conditions** (run is invalid, no result reported):
- Primary agent model substitution detected at trial 0 (runner refuses to start)
- A judge fails to score >10% of trials
- A/A noise floor > ±0.05 on the calibration subset

## 7. Analysis plan

1. Compute per-task composite score for each cell
2. Compute cell means + Wilson 95% CI
3. Compute paired delta B−A with bootstrapped CI (10,000 resamples, BCa)
4. Compute A/A noise floor delta with same CI
5. Compute padding-confound delta: C−A. If |C−A| > 0.5 × |B−A|, the length confound dominates; report B−A but caveat as not interpretable as cognition-content signal
6. Compute judge kappa per cell
7. Apply decision rule (§9)

## 8. Exclusion rules

- A trial is excluded only if: (a) API returned 5xx for all retries, OR (b) judge could not score (response truncated below 10 tokens)
- Excluded count must be ≤ 5 per cell, otherwise re-run that cell
- Excluded trials reported in the result doc with reason codes

## 9. Decision rule

| Outcome | Interpretation | Action |
|---|---|---|
| Wilson lower bound on (B−A) > 0.05, AND \|C−A\| < 0.5 × \|B−A\|, AND judge kappa > 0.4 | **Stack works** | Keep cognition defaults; ship to all fleet workers |
| Wilson CI on (B−A) crosses zero, OR (B−A) point estimate < 0.03 | **Null** | Gut the lesson-injection (META-040 already flagged ineffective lessons); cognition stack is faith-based; do not file new cognition-stack gaps until a re-run shows positive signal |
| \|C−A\| > 0.5 × \|B−A\| | **Length confound dominates** | Stack might work, but not for the reason claimed; re-design with content-matched control |
| Judge kappa < 0.4 | **Judges disagree** | Run is uninterpretable; reformulate rubric and re-run |
| n incomplete (<50/cell after 48h) | **Underpowered** | Treat as re-baseline; do not draw cognition-stack conclusions |

## 10. Budget

- **Primary agent (Sonnet 4.6):** estimated ~$3-5 across 200 trials
- **Confirmatory agent (Haiku 4.5):** estimated <$1 across 75 trials
- **Judge 1 (Haiku 4.5):** estimated <$1 across 250 scoring passes
- **Judge 2 (Llama-3.3-70B / Together free tier):** $0
- **Wall-clock target:** 24h primary + 12h confirmatory (slack to 48h)
- **Hard cap:** $15 total; halt if exceeded
- **Smoke-check first:** run n=2 per cell ($0.05 total) end-to-end and verify result-doc-rendering pipeline works before launching the n=50 sweep (per RESEARCH_INTEGRITY anti-EVAL-076-pattern)

## 11. Runtime enforcement (the new bit)

EVAL-101 failed because nothing checked the running config against the
preregistered config. This re-run enforces:

1. **Prereg-config lock**: this doc has a YAML frontmatter block at the
   bottom (§12) with locked fields. The runner reads it, asserts every
   env var and CLI flag matches, refuses to start otherwise.
2. **Deviation-fail-closed**: if the runner detects ANY mismatch (model
   substitution, missing judge, n target lowered), it exits non-zero
   with a clear error naming the mismatched field. No `||true` fallback.
3. **Result-doc consistency check**: when writing the result doc, the
   runner re-asserts model+n+cells matched the prereg, prints
   "PROTOCOL-DEVIATION" in the title if any field drifted mid-run.
4. **Append-only deviation log**: deviations write to §13 (this doc)
   with timestamp + commit SHA of the runner binary. Operator review
   required to interpret a deviated run.

These enforcement steps are tracked as a follow-up gap (sibling to
EVAL-102 in the same PR family) so they ship BEFORE the EVAL-102 sweep
runs, not after.

## 12. Locked-fields manifest (machine-readable)

```yaml
# scripts/eval/run-eval-102.sh asserts every key matches before launch.
prereg_locked:
  gap_id: EVAL-102
  cells:
    A: { reflection: 0, neuromod: 0, semantic_lessons: 0, lessons_at_spawn_n: 0 }
    B: { reflection: 1, neuromod: 1, semantic_lessons: 1, lessons_at_spawn_n: 5 }
    C: { reflection: 0, neuromod: 0, semantic_lessons: 0, lessons_at_spawn_n: 0, padding_tokens: 500 }
    A_prime: { reflection: 0, neuromod: 0, semantic_lessons: 0, lessons_at_spawn_n: 0, seed_offset: 1 }
  n_per_cell: 50
  primary_agent: claude-sonnet-4-6
  confirmatory_agent: claude-haiku-4-5
  judge_models:
    - claude-haiku-4-5
    - meta-llama/Llama-3.3-70B-Instruct
  fixture: scripts/ab-harness/fixtures/reflection_tasks.json
  primary_metric: composite_structural_and_judge_consensus
  decision_rule_version: 1
  budget_hard_cap_usd: 15
  wall_clock_hard_cap_hours: 48
```

## 13. Deviations (append-only, timestamped)

*(none yet — populated during/after the run)*
