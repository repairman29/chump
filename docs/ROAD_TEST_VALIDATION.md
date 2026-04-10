# Road-test and validate Chump

How to validate the full agent stack (consciousness modules, tools, SQLite) on your machine. Prefer **local** inference (Ollama `qwen2.5:7b` or MLX on `:8000`) so results are reproducible without cloud variance.

## Quick smoke test

```bash
cargo build --release
CHUMP_HEALTH_PORT=9191 OPENAI_API_BASE=http://127.0.0.1:11434/v1 OPENAI_API_KEY=ollama OPENAI_MODEL=qwen2.5:7b \
  ./target/release/chump --chump "What is 2 + 2?"
curl -s http://127.0.0.1:9191/health | python3 -m json.tool
```

Confirm `consciousness_dashboard` in JSON includes `surprise`, `belief_state`, `neuromodulation`, `holographic_workspace`, `phi`, `precision`, `blackboard`, `counterfactual`, `memory_graph`.

## Full exercise battery (28 prompts)

```bash
./scripts/consciousness-baseline.sh
cp logs/consciousness-baseline.json logs/consciousness-baseline-BEFORE.json
./scripts/consciousness-exercise.sh
diff logs/consciousness-baseline-BEFORE.json logs/consciousness-baseline-AFTER.json
```

On Ollama, the script **ignores** `OPENAI_MODEL` from `.env` and uses `qwen2.5:7b` unless you set `CHUMP_EXERCISE_MODEL`. Per-prompt wall time is capped by `CHUMP_EXERCISE_TIMEOUT` (default 240s).

## Consciousness ON vs OFF (mini A/B)

```bash
./scripts/consciousness-ab-mini.sh
diff logs/baseline-AB-ON.json logs/baseline-AB-OFF.json
```

For a full 28-prompt comparison, run `CHUMP_CONSCIOUSNESS_ENABLED=1 ./scripts/consciousness-exercise.sh` and `CHUMP_CONSCIOUSNESS_ENABLED=0 ./scripts/consciousness-exercise.sh` off-peak and compare baselines.

## Discord (manual)

1. Set `CHUMP_HEALTH_PORT=9191` (and `DISCORD_TOKEN`) in `.env`.
2. Start: `./run-discord.sh` (or `CHUMP_HEALTH_PORT=9191 ./run-discord.sh` if not in `.env`).
3. In Discord, use natural prompts that hit memory, tasks, episodes, and repo tools.
4. In another terminal: `watch -n 10 'curl -s http://127.0.0.1:9191/health | python3 -m json.tool | head -80'`

## Regression gates

```bash
cargo test
# Full suite is long (500 queries × iterations). Smoke:
BATTLE_QA_MAX=25 BATTLE_QA_ITERATIONS=1 OPENAI_MODEL=qwen2.5:7b ./scripts/battle-qa.sh
# Full run when you have time:
BATTLE_QA_ITERATIONS=5 ./scripts/battle-qa.sh
./scripts/consciousness-report.sh --json
```

## What “validated” means here

- Release binary runs against local Ollama/MLX without panics.
- Exercise battery completes (some `TIMEOUT` rows are acceptable on slow hardware; raise `CHUMP_EXERCISE_TIMEOUT` or use a faster local model).
- SQLite baselines move (predictions, episodes, lessons) between BEFORE and AFTER.
- `/health` reflects live module state during a session.
