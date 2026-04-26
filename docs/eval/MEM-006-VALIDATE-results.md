# MEM-006-VALIDATE: Spawn-Loaded Lessons A/B

**Gap:** MEM-006-VALIDATE
**Status:** methodology shipped; sweep pending (requires TOGETHER_API_KEY + runtime)
**Harness:** `scripts/ab-harness/run-spawn-lessons-ab.py`
**Last updated:** 2026-04-20

> **RESEARCH INTEGRITY:** All results are preliminary per `docs/process/RESEARCH_INTEGRITY.md`
> until the sweep completes with a cross-family judge panel. No model-architecture
> claims should be drawn from these results — this is an instruction-injection
> measurement only.

---

## 1. Background

MEM-006 (PR #153) shipped `load_spawn_lessons()` and `CHUMP_LESSONS_AT_SPAWN_N` in
`src/agent_loop/prompt_assembler.rs`. When `CHUMP_LESSONS_AT_SPAWN_N=N` is set,
the top-N recency×frequency-ranked improvement targets from `chump_improvement_targets`
are prepended to the assembled system prompt *before* the user-provided base — before
the agent sees the task.

The existing `run-cloud-v2.py` harness calls provider APIs directly, bypassing Chump's
prompt assembler entirely. Spawn-lesson injection is therefore never exercised by the
standard harness. This gap documents the validation methodology and the harness script
that can be run to produce empirical results.

---

## 2. Hypothesis

> Prepending spawn-loaded lessons from prior episodes improves task correctness (is_correct)
> compared to a no-lessons baseline, with the effect concentrated in "gotcha" tasks —
> scenarios where the lessons encode relevant guard-rails (write-before-check,
> ambiguity-without-clarify, retry-without-diagnosis, etc.).
>
> Null hypothesis: spawn-loaded lessons have no statistically distinguishable effect
> (Wilson 95% CIs overlap on all axes).

Secondary hypothesis: spawn lessons may increase hallucinated_tools on weak agent
tiers, consistent with prior COG-016 / EVAL-025 findings that lessons injection
backfires on certain model families.

---

## 3. Cell Design

| Cell | `CHUMP_LESSONS_AT_SPAWN_N` | `CHUMP_REFLECTION_INJECTION` | Description |
|------|---------------------------|------------------------------|-------------|
| A    | `5`                        | `0`                          | Spawn-loaded lessons injected; per-task injection OFF (isolated variable) |
| B    | unset                      | `0`                          | No lessons at all (baseline) |

`CHUMP_REFLECTION_INJECTION=0` is set in both cells to isolate the spawn path
(MEM-006) from the per-task path (COG-007/COG-009). Without this, cell B would
still inject lessons via the per-task path, contaminating the comparison.

**python mode (Option B):** the harness loads lessons from `sessions/chump_memory.db`
directly and formats them using the same wording as `format_lessons_block()` in
`src/reflection_db.rs`. When the DB is absent (clean-room environment), cell A
uses an empty lessons block — this measures format overhead only. Document this
if DB is absent.

---

## 4. Parameters

| Parameter | Value |
|-----------|-------|
| n per cell | 50 |
| Fixture | `scripts/ab-harness/fixtures/reflection_tasks.json` (first 50 tasks) |
| Agent model | `together:Qwen/Qwen2.5-7B-Instruct-Turbo` (free tier) |
| Judge model | `together:meta-llama/Llama-3.3-70B-Instruct-Turbo` (cross-family) |
| Judge threshold | 0.5 |
| spawn_n | 5 |
| Total API cost estimate | ~$0.03 (agent: ~$0.01, judge: ~$0.02) |

Cross-family judge is mandatory per methodology: Llama judges avoid the
Anthropic-judge reward-hallucination bias documented in EVAL-010 (PR #241).

---

## 5. Harness Invocation

### Option A (preferred): chump binary

Requires a built `chump` binary and `OPENAI_API_BASE` + `OPENAI_MODEL` pointing
at Together's OpenAI-compatible endpoint.

```bash
# Build first
cargo build --release

# Set env
export TOGETHER_API_KEY=<your-key>
export OPENAI_API_BASE=https://api.together.xyz/v1
export OPENAI_MODEL=Qwen/Qwen2.5-7B-Instruct-Turbo
export OPENAI_API_KEY=$TOGETHER_API_KEY

# Run sweep (n=50 per cell, ~100 trials total)
python3 scripts/ab-harness/run-spawn-lessons-ab.py \
    --fixture scripts/ab-harness/fixtures/reflection_tasks.json \
    --tag mem006-spawn-lessons-qwen7b \
    --mode binary \
    --chump-bin ./target/release/chump \
    --model together:Qwen/Qwen2.5-7B-Instruct-Turbo \
    --judge together:meta-llama/Llama-3.3-70B-Instruct-Turbo \
    --limit 50
```

### Option B (fallback): Python-side injection

Does not require a built binary. Reads lessons directly from the SQLite DB
and calls Together directly.

```bash
export TOGETHER_API_KEY=<your-key>

python3 scripts/ab-harness/run-spawn-lessons-ab.py \
    --fixture scripts/ab-harness/fixtures/reflection_tasks.json \
    --tag mem006-spawn-lessons-qwen7b-py \
    --mode python \
    --model together:Qwen/Qwen2.5-7B-Instruct-Turbo \
    --judge together:meta-llama/Llama-3.3-70B-Instruct-Turbo \
    --limit 50 \
    --db sessions/chump_memory.db
```

### A/A control (noise floor calibration)

Run Option B with an empty DB (or absent DB path) to measure run-to-run noise
with zero lessons in both cells. Any delta in the A/B results must exceed the
A/A noise floor to be cited.

```bash
python3 scripts/ab-harness/run-spawn-lessons-ab.py \
    --fixture scripts/ab-harness/fixtures/reflection_tasks.json \
    --tag mem006-aa-control \
    --mode python \
    --model together:Qwen/Qwen2.5-7B-Instruct-Turbo \
    --judge together:meta-llama/Llama-3.3-70B-Instruct-Turbo \
    --limit 50 \
    --db /dev/null
```

---

## 6. Decision Criteria

After the sweep completes, read `logs/ab/<tag>-<ts>.summary.json` and apply:

| Condition | Recommendation |
|-----------|----------------|
| `deltas.is_correct.cis_overlap = false` AND `deltas.is_correct.delta > 0` | Cell A improves correctness → recommend `CHUMP_LESSONS_AT_SPAWN_N` default-on for opted-in models (add to `CHUMP_LESSONS_OPT_IN_MODELS` CSV for Qwen-7B) |
| `deltas.hallucinated_tools.cis_overlap = false` AND `deltas.hallucinated_tools.delta > 0` | Spawn lessons increase hallucination → do NOT default-on; document as harmful |
| `deltas.is_correct.cis_overlap = true` | Null result — no distinguishable effect at n=50; increase n or document null |

**If null result:** document in the results table below and in `docs/research/CONSCIOUSNESS_AB_RESULTS.md`
as "null result, recommend keeping default-off (COG-024 safe-by-default preserved)."

---

## 7. Results

> **Status: pending** — sweep has not been executed. Run the harness commands above
> with a valid `TOGETHER_API_KEY` to populate this section.

### 7.1 Sweep parameters

| Parameter | Value |
|-----------|-------|
| Date | TBD |
| Git SHA | TBD |
| n per cell | TBD |
| DB lessons loaded | TBD |

### 7.2 Per-cell rates

| Cell | is_correct rate | 95% CI | did_attempt | halluc rate | mean_judge_score |
|------|-----------------|--------|-------------|-------------|-----------------|
| A (spawn ON)  | TBD | TBD | TBD | TBD | TBD |
| B (spawn OFF) | TBD | TBD | TBD | TBD | TBD |

### 7.3 Deltas

| Axis | Δ (A−B) | CIs overlap? | Signal? |
|------|---------|-------------|---------|
| is_correct | TBD | TBD | TBD |
| did_attempt | TBD | TBD | TBD |
| hallucinated_tools | TBD | TBD | TBD |

### 7.4 Verdict

> TBD — run the sweep and replace this line with one of:
> - "Cell A > Cell B on is_correct (non-overlapping CIs) → recommend default-on for Qwen-7B"
> - "Null result — CIs overlap on all axes; default-off preserved"
> - "Cell A worse on hallucination axis → harmful; default-off preserved"

---

## 8. Key implementation notes

### Why spawn lessons are different from per-task lessons

Per-task lessons (COG-007/COG-009) are loaded fresh on each call to
`PromptAssembler::assemble()`, scoped to the current detected entities. Spawn lessons
(MEM-006) are loaded once at agent start, ranked by recency×frequency across ALL prior
episodes, and injected *first* in the prompt before the user-provided base system
prompt. The hypothesized benefit: persistent meta-knowledge from prior runs primes the
agent before it has parsed the task.

### Isolation: why `CHUMP_REFLECTION_INJECTION=0`

Without this flag, cell B would still inject per-task lessons via the COG-007 path.
This isolation flag is required so the sweep measures MEM-006 (spawn path) in
isolation, not the combined effect of both injection paths. Binary mode sets this
automatically in the subprocess env; python mode does not call the assembler so no
isolation is needed (lessons are either injected by the harness or not).

### Lesson quality threshold

`CHUMP_LESSON_QUALITY_THRESHOLD` defaults to 0.0 (include all lessons). For the
sweep, leave this unset — a production recommendation can include quality filtering,
but the validation sweep should measure the raw effect first.

### DB absent scenario

If `sessions/chump_memory.db` is absent in python mode, cell A uses an empty lessons
block and cell B uses None. The A/B delta will measure format-header overhead only
(not actual lessons content). The harness prints a warning in this case. If the DB
is absent, note this in the results section and consider running with a seeded DB.
