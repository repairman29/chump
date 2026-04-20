# EVAL-030-VALIDATE: Task-Class-Aware Lessons Gating — A/B/C Harness Protocol

**Gap ID:** EVAL-030-VALIDATE
**Date:** 2026-04-20
**Status:** PRELIMINARY — harness extended; results pending (API sweep not yet run)
**Depends on:** EVAL-030 (shipped the production gating code)
**Integrity note:** Per `docs/RESEARCH_INTEGRITY.md`, results are preliminary until
the sweep runs with n≥50 per cell, a non-Anthropic judge in the panel, and an A/A
noise-floor run. Do not cite any deltas from this doc as validated findings.

---

## 1. Background

EVAL-030 shipped task-class-aware lessons gating in `src/reflection_db.rs`:

- **Trivial tokens** (prompts < 30 chars trimmed) → skip the lessons block entirely.
- **Conditional-chain prompts** (≥2 conditional markers OR explicit `step 1`/`step 2` sequence)
  → strip the `[perception]` "ask one clarifying question" directive; keep the rest.
- **Normal prompts** → inject the full cog016 lessons block unchanged.

The gating is controlled by `CHUMP_LESSONS_TASK_AWARE` (default ON). EVAL-029 identified
the two harm mechanisms: (a) lessons block injection on trivial tokens causes over-formalization,
(b) the perception clarify directive on conditional-chain tasks causes harmful early-stopping
mid-chain.

The v2 cloud harness (`scripts/ab-harness/run-cloud-v2.py`) previously built the lessons block
as a static Python constant and did NOT dispatch through `prompt_assembler.rs`, so it could not
exercise the EVAL-030 gating. This gap closes that hole by adding a Python port of the two
heuristics and a new `--mode abc` sweep design.

---

## 2. Python Port of Heuristics

The gating logic from `src/reflection_db.rs` was ported to Python in the harness. The three
relevant functions are in `run-cloud-v2.py`:

**`is_trivial_token(prompt: str) -> bool`**
```python
return len(prompt.strip()) < 30
```
Mirrors `reflection_db::is_trivial_token()` exactly.

**`is_conditional_chain(prompt: str) -> bool`**
```python
lc = prompt.lower()
cond_markers = ["if it fails", "if that fails", "then if", "else if", "if not"]
cond_count = sum(1 for m in cond_markers if m in lc)
step_pattern = ("step 1" in lc and "step 2" in lc)
return cond_count >= 2 or step_pattern
```
Mirrors `reflection_db::is_conditional_chain()` exactly (same markers, same thresholds).

**`build_task_aware_system(base_block: str, prompt: str) -> str | None`**
Applies the gating logic: returns `None` for trivial tokens, a filtered block (perception
directive stripped) for conditional chains, and the full base block for normal prompts.
The base block used is `LESSONS_BLOCK_COG016` (the production cog016 format).

The perception-directive filter matches on the substring `"(P1) [perception]"`, which is
the exact prefix used in `LESSONS_BLOCK_COG016`. This mirrors the substring check in
`reflection_db::is_perception_clarify_directive()`.

---

## 3. Three-Cell ABC Design

The new `--mode abc` option (used with `--lessons-version task-aware`) runs three cells per task:

| Cell | Condition | Description |
|------|-----------|-------------|
| A | Task-aware (EVAL-030) | `build_task_aware_system()` applied per task — no block on trivial, filtered block on conditional chain, full block on normal |
| B | No lessons | No system prompt (ablation baseline) |
| C | v1-uniform cog016 | Full `LESSONS_BLOCK_COG016` regardless of task class |

**Acceptance criteria (from gap spec):**
- Cell-A `is_correct` ≥ Cell-B `is_correct` (task-aware does no harm vs. no-lessons)
- Cell-A vs Cell-C delta near zero on non-gated tasks (task-aware preserves uniform benefits)
- Cell-A vs Cell-C negative delta on gated tasks (conditional-chain / trivial) — this is the win

**Key deltas computed in summary.json:**
- `deltas.is_correct`: A vs B (task-aware vs no-lessons)
- `deltas.hallucinated_tools`: A vs B
- `deltas.is_correct_A_vs_C`: A vs C (task-aware vs uniform)
- `deltas.hallucinated_tools_A_vs_C`: A vs C
- `by_cell.A.per_task_class`: per-class breakdown for cell A (trivial / conditional / normal)

---

## 4. Reproduction Commands

### Step 1: A/A noise-floor calibration (required before citing results)

```bash
python3 scripts/ab-harness/run-cloud-v2.py \
    --fixture scripts/ab-harness/fixtures/reflection_tasks.json \
    --tag eval030-validate-aa-haiku45 \
    --mode aa \
    --model claude-haiku-4-5 \
    --judge claude-sonnet-4-5,together:meta-llama/Llama-3.3-70B-Instruct-Turbo \
    --limit 50
```

Expected: A/A delta within ±0.03 on all axes. If not, do not proceed.

### Step 2: Main three-cell sweep on haiku-4-5 (n=50)

```bash
python3 scripts/ab-harness/run-cloud-v2.py \
    --fixture scripts/ab-harness/fixtures/reflection_tasks.json \
    --tag eval030-validate-haiku45 \
    --mode abc \
    --lessons-version task-aware \
    --model claude-haiku-4-5 \
    --judge claude-sonnet-4-5,together:meta-llama/Llama-3.3-70B-Instruct-Turbo \
    --limit 50
```

### Step 3: Replication on a Qwen size point (n=50)

```bash
python3 scripts/ab-harness/run-cloud-v2.py \
    --fixture scripts/ab-harness/fixtures/reflection_tasks.json \
    --tag eval030-validate-qwen72b \
    --mode abc \
    --lessons-version task-aware \
    --model together:Qwen/Qwen2.5-72B-Instruct-Turbo \
    --judge claude-sonnet-4-5,together:meta-llama/Llama-3.3-70B-Instruct-Turbo \
    --limit 50
```

**Environment variables required:**
- `ANTHROPIC_API_KEY` — for Anthropic model inference and claude-sonnet judge
- `TOGETHER_API_KEY` — for Together.ai model inference and Llama judge (free tier eligible)

Estimated cost: ~$1–2 cloud (haiku-4-5 is cheap; Together free tier covers Llama judge).

---

## 5. Results (PENDING)

> **Status: Results pending.** The harness extension was merged on 2026-04-20 but the
> actual sweep has not been run (requires API keys and compute). Deltas below are
> placeholder structure only — do not cite.

### 5a. A/A Noise Floor

| Tag | Model | n | Δ is_correct | Δ halluc |
|-----|-------|---|--------------|----------|
| _pending_ | claude-haiku-4-5 | 50 | — | — |

### 5b. Three-Cell Results: haiku-4-5

| Cell | n | correct_rate [95% CI] | halluc_rate | mean_judge |
|------|---|-----------------------|-------------|------------|
| A (task-aware) | _pending_ | — | — | — |
| B (no-lessons) | _pending_ | — | — | — |
| C (v1-uniform) | _pending_ | — | — | — |

**A vs B deltas:**

| Axis | Δ | 95% CIs overlap? | Interpretation |
|------|---|------------------|----------------|
| is_correct | — | — | — |
| hallucinated_tools | — | — | — |

**A vs C deltas (task-aware vs uniform):**

| Axis | Δ | 95% CIs overlap? | Interpretation |
|------|---|------------------|----------------|
| is_correct | — | — | — |
| hallucinated_tools | — | — | — |

**Per-task-class breakdown (cell A only):**

| Task class | n | correct_rate | Notes |
|------------|---|--------------|-------|
| trivial_token | — | — | No block injected |
| conditional_chain | — | — | Perception directive stripped |
| normal | — | — | Full cog016 block |

### 5c. Three-Cell Results: Qwen 72B

_pending_

---

## 6. Methodology Notes

Per `docs/RESEARCH_INTEGRITY.md`:

1. **Sample size:** n=50 per cell meets the minimum for directional signal. n=100 required
   before results can influence ship/cut decisions on EVAL-030 gating.

2. **Judge composition:** The recommended sweep uses a two-judge panel:
   `claude-sonnet-4-5` (Anthropic) + `together:meta-llama/Llama-3.3-70B-Instruct-Turbo`
   (non-Anthropic). Median verdict is reported. This satisfies the cross-family requirement.

3. **A/A baseline:** Step 1 above must pass (Δ ≤ ±0.03) before results are cited.

4. **Task-class coverage:** The reflection_tasks fixture contains predominantly
   `reflection` and `perception` category tasks. A separate conditional-chain fixture
   may be needed to ensure adequate coverage of the `conditional_chain` class — the
   harness's `per_task_class` breakdown will reveal if the fixture contains zero
   conditional-chain tasks, which would make the gating untestable on this fixture.
   If zero conditional-chain tasks are detected, file a follow-up gap to add
   conditional-chain tasks to the fixture.

5. **Mechanism analysis:** If cell-A outperforms cell-C on conditional-chain tasks
   (Δ > +0.05), the expected mechanism is: suppression of the perception clarify
   directive removes the early-stopping failure mode documented in EVAL-029.
   If cell-A underperforms cell-C on normal tasks, investigate whether the
   `_PERCEPTION_CLARIFY_SUBSTR` filter is too broad and is accidentally stripping
   non-harmful directives.

---

## 7. Related Gaps

- **EVAL-030** (done): shipped the production gating code in `src/reflection_db.rs`
- **EVAL-029** (done): neuromod task-drilldown that identified the two harm mechanisms
- **EVAL-043**: full ablation suite — includes gating as one of the isolation cells
- **EVAL-041**: human grading — validates judge accuracy on conditional-chain tasks
