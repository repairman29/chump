# Battle QA: 500 User Queries

Deep testing and QA for Chump: a job that runs **500 user queries** against the Chump CLI and reports pass/fail. Re-run until all pass to be "ready for battle."

## Quick start

From repo root:

```bash
# One-command full run + report (writes logs/battle-qa-report.txt)
./scripts/run-battle-qa-full.sh

# Or run battle-qa directly (500 queries, ~90s each in worst case; use BATTLE_QA_MAX for smoke)
./scripts/battle-qa.sh

# Smoke: first 50 only
BATTLE_QA_MAX=50 ./scripts/battle-qa.sh

# Re-run up to 5 times until all pass (fix code between runs)
BATTLE_QA_ITERATIONS=5 ./scripts/battle-qa.sh

# Shorter timeout, resume after first 100
BATTLE_QA_TIMEOUT=60 BATTLE_QA_SKIP=100 ./scripts/battle-qa.sh
```

## Self-heal (Chump fixes himself)

When you say "run battle QA and fix yourself" or "battle QA self-heal", Chump uses `run_battle_qa` (smoke), reads `logs/battle-qa-failures.txt`, edits code or scripts, and re-runs until all pass or 5 rounds. See [BATTLE_QA_SELF_FIX.md](BATTLE_QA_SELF_FIX.md).

## Testing against a specific config (default vs max M4)

You can run the same tests against either the **default** config (Ollama 11434) or the **max_m4** config (vLLM-MLX on 8000 only, 14B, in-process embeddings) without editing `.env`.

- **Default (Ollama):** `./scripts/run-tests-with-config.sh default battle-qa.sh` — or run `./scripts/battle-qa.sh` directly as today.
- **Max M4 (vLLM-MLX 8000):** Build with `cargo build --release --features inprocess-embed`, start only vLLM-MLX on port 8000 (no 8001, no Python embed server), then:
  ```bash
  ./scripts/run-tests-with-config.sh max_m4 battle-qa.sh
  ```
  Example smoke: `./scripts/run-tests-with-config.sh max_m4 battle-qa.sh BATTLE_QA_MAX=50`

Supported test scripts: `battle-qa.sh`, `run-autonomy-tests.sh`, `test-heartbeat-learn.sh`, and any other script that uses `OPENAI_API_BASE` from the environment. The runner sources the profile env, runs preflight (model server reachable), then runs the requested script.

## Requirements

- **Model:** Default is **Ollama on 11434** (same as `run-discord.sh`). Preflight checks 11434. Start with `ollama serve` and pull a model (e.g. `ollama pull qwen2.5:14b`).
- **CHUMP_REPO** or **CHUMP_HOME** set in `.env` for repo tools (read_file, list_dir, task, etc.). Optional for calc/memory/run_cli-only.
- Build: `cargo build --release` recommended so each query runs fast (no recompile). For **max_m4** use `cargo build --release --features inprocess-embed`.

## What it does

1. **Generates 500 queries** via `scripts/qa/generate-battle-queries.sh` (or uses cached `scripts/qa/battle-queries.txt`).
2. **Runs each query** with `rust-agent --chump "<query>"` under a per-query timeout (default 90s).
3. **Pass heuristic:** exit code 0 and the last 2k chars of output do not contain a line starting with `Error: ` or `error:` (agent/tool error).
4. **Logs:** `logs/battle-qa.log`, `logs/battle-qa-results.json`, `logs/battle-qa-failures.txt` (failed id, category, query, and last 500 chars of output).
5. **Iterations:** If `BATTLE_QA_ITERATIONS` > 1, the script re-runs the full suite up to that many times; it exits 0 on first full pass, else 1 after the last run.

## Query categories

| Category   | Count | Description                    |
| ---------- | ----- | ------------------------------ |
| calc       | 50    | Calculator (math, number only) |
| memory     | 40    | Store / recall                 |
| run_cli    | 100+  | run_cli (pwd, ls, cargo, git)  |
| read_file  | 30    | read_file repo paths           |
| list_dir   | 20    | list_dir repo paths            |
| task       | 25    | task create / list            |
| chat       | 40    | Simple chat, no tools          |
| edge       | 30    | Empty, 0, short replies        |
| repo       | 20    | Repo tools (read/list)         |
| multi      | 35    | Multi-step (cli + memory, etc.)|
| ego        | 15    | Ego tool                       |
| safety     | 30    | Path escape, dangerous cmd    |
| (fill)     | rest  | To 500                         |

## Env vars

| Env                    | Default | Description                          |
| ---------------------- | ------- | ------------------------------------ |
| BATTLE_QA_QUERIES      | scripts/qa/battle-queries.txt | Query file path              |
| BATTLE_QA_TIMEOUT     | 90      | Seconds per query                    |
| BATTLE_QA_SKIP        | 0       | Skip first N queries                |
| BATTLE_QA_MAX         | 500     | Max queries to run (0 = all)         |
| BATTLE_QA_ITERATIONS  | 1       | Re-run suite up to N times until pass |
| BATTLE_QA_ACCEPT_TIMEOUT_OK | (unset) | If set (e.g. 1), treat timeout (124) as pass when output has no error and tail &gt; 300 chars (lenient for slow/verbose runs). |

## Exit codes

- **0** — All queries passed (or passed on a re-run iteration).
- **1** — Preflight failed (no model) or at least one query failed after all iterations.

## Simulations (no user research)

Use these to surface bugs before interviews or long battle runs:

| What | Command | Notes |
| ---- | ------- | ----- |
| **Unit + in-process API contract** | `cargo test` | `web_server::api_battle_tests`: health, cascade, task validation, auth, pilot-summary when DB OK. |
| **CLI, no model** | `./scripts/battle-cli-no-llm.sh` | Exercises `chump --chump-due` (schedule path). |
| **Live web API (black-box)** | `./scripts/battle-api-sim.sh` | Requires `chump --web` on `CHUMP_WEB_PORT`. Same `CHUMP_WEB_TOKEN` as server if auth is on. Log: `logs/battle-api-sim.log`. |
| **Orchestrator** | `./scripts/run-battle-sim-suite.sh` | Runs `cargo test` + CLI sim; set `BATTLE_SIM_WEB=1` if web is up; set `BATTLE_SIM_LLM=1` for a short LLM battle (needs model). CI uses `BATTLE_SIM_SKIP_CARGO=1` after `cargo test` so the suite does not run tests twice. |
| **Fast LLM battle set** | `BATTLE_QA_QUERIES=scripts/qa/battle-fast-queries.txt BATTLE_QA_MAX=60 ./scripts/battle-qa.sh` | ~50 diverse queries (calc, memory, tools, safety). Custom `BATTLE_QA_QUERIES` paths are never overwritten (only `scripts/qa/battle-queries.txt` is auto-generated to 500 lines). |

## Fix loop (ready for battle)

1. Run: `BATTLE_QA_ITERATIONS=3 ./scripts/battle-qa.sh`.
2. If it exits 1, open `logs/battle-qa-failures.txt` and fix the causes (path errors, tool bugs, model behavior).
3. Optionally run `cargo test` and fix unit tests.
4. Re-run from step 1 until the script exits 0.

You can also run once, fix, then run again manually until you're satisfied.

## See also

- [BATTLE_QA_FAILURES.md](BATTLE_QA_FAILURES.md) — Fix list from last run (id, category, query) and root-cause notes.
- `scripts/qa/battle-fast-queries.txt` — Curated short list for `BATTLE_QA_QUERIES`.
- [CHUMP_AUTONOMY_TESTS.md](CHUMP_AUTONOMY_TESTS.md) — Tier 0–5 autonomy tests.
- [OPERATIONS.md](OPERATIONS.md) — Run/serve, env reference.
