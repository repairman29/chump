# EVAL-039 — Longitudinal Learning A/B: Does the Reflection Accumulation Loop Work?

**Gap:** EVAL-039
**Date filed:** 2026-04-20
**Status:** Infrastructure shipped — pilot run PENDING (requires API keys, ~4 hrs wall time)
**Priority:** P3
**Effort:** L

---

## Purpose

Prior evals (EVAL-025, MEM-006-VALIDATE) tested whether a **hand-authored** lessons block helps at
inference time. EVAL-039 tests the orthogonal question: does the **accumulation loop itself** work?

The accumulation loop is: complete a task → `episode_extractor` generates a reflection →
`reflection_db` writes an improvement target → `load_spawn_lessons` reads it back at the next
spawn → the agent performs better.

If this loop compounds, the agent should improve monotonically as N (number of prior episodes)
grows. If the loop is mechanical but not beneficial, the pass-rate trajectory will be flat across N.

---

## Hypothesis

**H1 (positive):** Pass rate grows monotonically across N = {0, 10, 50, 100} and at least one
adjacent pair of cells has non-overlapping Wilson 95% CIs.

**H0 (null):** Pass rate is flat across N cells (all deltas within CI noise band).

A positive result (H1) validates the accumulation loop as a real learning channel. A null result
does not disprove the loop mechanically works — it may mean the synthetic seeding content is too
uniform, N values are insufficient, or the spawn-injection path has a coverage gap.

---

## Key Distinction from MEM-006-VALIDATE

| | MEM-006-VALIDATE | EVAL-039 |
|--|--|--|
| **What varies** | Lessons ON vs OFF (binary) | N prior episodes (0, 10, 50, 100) |
| **Lesson source** | Hand-authored DB seeds | Synthetic episodes from `seed-reflection-db.py` |
| **Question** | Does any lessons block help? | Does accumulation compound? |
| **Positive signal** | A > B with non-overlapping CIs | Monotone increase across N cells |

---

## Methodology

### Cells

| Cell | N prior episodes | Expected lessons loaded at spawn |
|------|-----------------|----------------------------------|
| N=0  | 0 (baseline)    | 0 (empty DB)                     |
| N=10 | 10              | up to 5 (CHUMP_LESSONS_AT_SPAWN_N=5) |
| N=50 | 50              | up to 5                          |
| N=100| 100             | up to 5                          |

Each cell uses the same fixture and model. The only variable is the DB state at lesson load time.

### Seeding Approach

`scripts/ab-harness/seed-reflection-db.py` seeds N synthetic `chump_reflections` rows and
1-3 `chump_improvement_targets` per reflection. Content is drawn from 20 realistic directives
covering the same domains as real Chump lessons:

- **tool_middleware** (check before write, correct tool class, no fake markup)
- **perception** (clarify before acting, resist urgency/authority framing)
- **agent_loop** (no retry loops, convert narration to tool calls)
- **task_planner** (decompose before executing, scope confirmation)

Seeded rows are tagged `error_pattern LIKE 'longitudinal_seed:%'` so they can be identified and
cleared independently of real production reflections.

At spawn time, `load_spawn_lessons_with_threshold()` ranks targets by:

```
score = COUNT(*) / (1.0 + (julianday('now') - julianday(MAX(created_at))) / 7.0)
```

All seed rows land at roughly the same timestamp, so **frequency is the primary ranking signal**:
directives that appear across more episodes (high-priority entries with doubled weight in the pool)
rank first and are most likely to be injected at spawn.

### Fixture

`scripts/ab-harness/fixtures/reflection_tasks.json` — 100 tasks (50 clean + 50 gotcha).
Gotcha tasks are the signal-bearing class: they test scenarios where the lessons block *should*
improve behavior (write-before-check, narration-instead-of-tools, ambiguity-without-clarify,
policy-gate bypass).

### Scoring

`scoring_v2.score_trial()` — multi-axis:

- `is_correct`: judge score >= 0.5 threshold
- `did_attempt`: made a real effort (not pure refusal)
- `hallucinated_tools`: emitted fake `<function_calls>` / `<tool_call>` markup

Primary outcome metric: `is_correct` pass rate per N-cell.

### Model and Judge

Recommended (low-cost, non-Anthropic judge):

- **Agent:** `together:Qwen/Qwen2.5-7B-Instruct-Turbo` (free tier)
- **Judge:** `together:meta-llama/Llama-3.3-70B-Instruct-Turbo` (free tier, cross-family)

Cross-family judge is required per `docs/RESEARCH_INTEGRITY.md`: Anthropic-only judging is
insufficient for publication (confirmed LLM judge bias in EVAL-010).

### Sample Size

n=50 tasks per cell is the minimum for directional signal (per `docs/RESEARCH_INTEGRITY.md`).
n=100 per cell is required before citing results as validated findings.

---

## Reproduction Command

```bash
python3 scripts/ab-harness/run-longitudinal-ab.py \
    --fixture scripts/ab-harness/fixtures/reflection_tasks.json \
    --model together:Qwen/Qwen2.5-7B-Instruct-Turbo \
    --judge together:meta-llama/Llama-3.3-70B-Instruct-Turbo \
    --n-cells 0,10,50,100 \
    --limit 50 \
    --db sessions/chump_memory.db \
    --tag eval039-longitudinal-$(date +%Y%m%d)
```

Seeding only (for debugging):

```bash
# Seed 50 episodes
python3 scripts/ab-harness/seed-reflection-db.py --n 50 --db sessions/chump_memory.db

# Clear all longitudinal seeds
python3 scripts/ab-harness/seed-reflection-db.py --n 0 --db sessions/chump_memory.db --clear
```

Quick smoke test (5 tasks, N=0 and N=10 only, ~5 minutes):

```bash
python3 scripts/ab-harness/run-longitudinal-ab.py \
    --fixture scripts/ab-harness/fixtures/reflection_tasks.json \
    --model together:Qwen/Qwen2.5-7B-Instruct-Turbo \
    --judge together:meta-llama/Llama-3.3-70B-Instruct-Turbo \
    --n-cells 0,10 \
    --limit 5 \
    --db sessions/chump_memory.db \
    --tag eval039-smoke
```

---

## Results

**PENDING — requires API keys and ~4 hrs to run the full trajectory.**

The harness infrastructure is complete. Run the reproduction command above with
`TOGETHER_API_KEY` set to collect results.

Expected output format (trajectory table):

```
  N  tasks   pass_rate    ci_low   ci_high   halluc  mean_judge
----------------------------------------------------------------------
  0     50      0.xxx     0.xxx     0.xxx    0.xxx       0.xxx
 10     50      0.xxx     0.xxx     0.xxx    0.xxx       0.xxx
 50     50      0.xxx     0.xxx     0.xxx    0.xxx       0.xxx
100     50      0.xxx     0.xxx     0.xxx    0.xxx       0.xxx
```

---

## Pre-Analysis: What Would Each Result Mean?

### Positive result (H1 confirmed)

Pattern: monotone pass-rate increase across N, at least one adjacent pair with non-overlapping CIs.

Example:
```
N=0:   pass_rate=0.42  [0.29–0.56]
N=10:  pass_rate=0.48  [0.34–0.62]  — within noise
N=50:  pass_rate=0.57  [0.43–0.70]  — approaching signal
N=100: pass_rate=0.66  [0.52–0.78]  — non-overlapping vs N=0
```

Interpretation: reflection accumulation compounds. The write→recall loop is a real learning
channel. Recommend setting a default `CHUMP_LESSONS_AT_SPAWN_N` value for opted-in models.

Caution: this result would be from synthetic episodes. The compounding signal with real
production reflections may be weaker (real data is noisier) or stronger (real data is more
task-relevant). File a followup to test with real episode accumulation.

### Null result (H0 retained)

Pattern: flat trajectory, all N-cells within CI noise band.

Example:
```
N=0:   pass_rate=0.52  [0.38–0.66]
N=10:  pass_rate=0.50  [0.36–0.64]  — within noise
N=50:  pass_rate=0.54  [0.40–0.67]  — within noise
N=100: pass_rate=0.51  [0.37–0.65]  — within noise
```

Interpretation: the accumulation loop does not produce measurable improvement at these N values
and with synthetic content. File a followup to investigate:

1. Is the synthetic content too uniform (top-ranked directive same across all N)?
2. Is `load_spawn_lessons` not excluding ab_seed rows correctly for longitudinal seeds?
3. Is the spawn injection path not firing (CHUMP_LESSONS_AT_SPAWN_N env var not set)?
4. Does the N range need to be larger (try N=500, N=1000)?
5. Would real production reflection content show a different trajectory?

### Harmful result

Pattern: pass rate decreases as N grows (hallucination rate increases with N).

Interpretation: the lessons block content is causing the same harm as EVAL-027c (sonnet-4-5
hallucination regression). Check:
- Is the model being tested a Sonnet-class model? Lessons harm Sonnet (EVAL-027c confirmed).
- Are the seeded directives triggering the "emit tool calls" failure mode?
- Is the hallucination guard ("do NOT emit function_calls markup") in the LESSONS_HEADER?

---

## Methodology Standards

Per `docs/RESEARCH_INTEGRITY.md`:

- Minimum n=50 per cell for directional signal; n=100 for ship-or-cut decisions
- At least one non-Anthropic judge in the panel
- A/A baseline run required before citing results (same N vs same N — measures judge variance)
- Mechanism analysis required for any delta > ±0.05
- `CHUMP_EXPERIMENT_CHECKPOINT` from `INFRA-EXPERIMENT-CHECKPOINT` should be set for reproduction

Do NOT cite any delta from this sweep as a finding if `cis_overlap=True` in the summary JSON.

---

## Cost Estimate

| Component | Estimate |
|-----------|---------|
| Seeding (SQLite writes) | $0.00 |
| Agent calls: 4 cells × 50 tasks × Qwen-7B | ~$0.01 |
| Judge calls: 200 calls × Llama-3.3-70B | ~$0.04 |
| **Total (full sweep)** | **~$0.05–$0.10** |
| Wall time (full sweep) | ~4 hrs (Together free tier rate limits) |

---

## Related Gaps

| Gap | Relationship |
|-----|-------------|
| EVAL-025 | Validated hand-authored lessons block on haiku-4-5 (prerequisite signal) |
| MEM-006-VALIDATE | Binary ON/OFF spawn-lessons A/B (different question) |
| EVAL-027c | Confirmed lessons block harms sonnet-4-5 (caution: avoid Sonnet for this sweep) |
| EVAL-030 | Task-class-aware gating (ensure `CHUMP_LESSONS_TASK_AWARE` is not suppressing lessons) |
| EVAL-042 | Cross-family judge re-run (apply same judge hygiene here) |
