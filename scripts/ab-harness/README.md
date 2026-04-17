# A/B harness

Generic runner for env-gated A/B experiments on chump. Replaces bespoke
per-gap scripts (consciousness-ab-mini.sh, etc.) with a single driver.

## Files

- **run.sh** — runner. Takes a fixture + env flag name + tag; runs each
  task twice (flag=1 then flag=0); emits JSONL per trial.
- **score.py** — consumes the JSONL + fixture, applies the structural
  property checks from `src/eval_harness.rs::check_property` (reimplemented
  in Python so we don't need a binary call), emits per-trial scored JSON
  + summary JSON.
- **append-result.sh** — takes a summary JSON + gap-id, appends a
  markdown block to `docs/CONSCIOUSNESS_AB_RESULTS.md`.
- **fixtures/** — seed task sets, one JSON file per experiment.
- **runs/** — gitignored; per-invocation artifacts if run.sh is asked
  to dump them (currently it writes to `logs/ab/` instead).

## Wire-in experiments

| Gap | Flag | Fixture |
|-----|------|---------|
| **COG-011** | `CHUMP_REFLECTION_INJECTION` | `fixtures/reflection_tasks.json` |
| COG-005 (future) | `CHUMP_PERCEPTION_ENABLED` | add `fixtures/perception_tasks.json` |
| COG-006 (future) | `CHUMP_NEUROMOD_ENABLED` | add `fixtures/neuromod_tasks.json` |

## Running COG-011 (the reference invocation)

```bash
# Build release binary if needed.
cargo build --release --bin chump

# Start Ollama with qwen2.5:7b (or MLX on :8000).
ollama serve &
ollama pull qwen2.5:7b

# Run the 20-task A/B. ~1-2 hrs.
scripts/ab-harness/run.sh \
    --fixture scripts/ab-harness/fixtures/reflection_tasks.json \
    --flag CHUMP_REFLECTION_INJECTION \
    --tag reflection-ab \
    --limit 20

# Score it.
scripts/ab-harness/score.py \
    logs/ab/reflection-ab-<TIMESTAMP>.jsonl \
    scripts/ab-harness/fixtures/reflection_tasks.json

# Append result to the registry.
scripts/ab-harness/append-result.sh \
    logs/ab/reflection-ab-<TIMESTAMP>.summary.json \
    COG-011 \
    --note "qwen2.5:7b baseline, 20 tasks, heuristic structural scoring"
```

Background mode: add `&` to the `run.sh` invocation and pipe stdout to a
log file. Check progress with `tail -f logs/ab/reflection-ab-*.jsonl`
— each line is one completed trial.

## Resumability

If a run dies mid-way, point the next invocation at the existing JSONL
with `--resume`:

```bash
scripts/ab-harness/run.sh ... --resume logs/ab/reflection-ab-1776449999.jsonl
```

Already-recorded `(task_id, mode)` pairs are skipped; missing ones are
filled in. Same file gets extended; score afterwards as usual.

## Design caveats

- **Structural scoring only (MVP).** Properties are evaluated by text
  match + tool-call presence. LLM-judge scoring (semantic correctness)
  is COG-011b.
- **Deterministic order — A then B** per task. Biases toward "same session
  conditions for both modes"; a randomized or reversed follow-up (COG-011c)
  would strengthen the causal claim.
- **Single model per run.** Multi-model scaling (e.g. 3B / 9B / 14B) is
  COG-001, and this harness is compatible — pass `OPENAI_MODEL=...` per
  invocation.
