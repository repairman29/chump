# Chump

**This repo ([github.com/repairman29/chump](https://github.com/repairman29/chump)) is THE canonical repo for all things Chump.** All Chump development happens here.

Local AI agent (Rust + [AxonerAI](https://crates.io/crates/axonerai)) talking to an OpenAI-compatible API. Discord bot + CLI; tools for memory, repo, GitHub, tasks, schedule, and self-audit. **Local inference: Ollama by default (Qwen 2.5 14B); no Python in the agent runtime.** Works with any OpenAI-compatible server.

## Build and run

```bash
cargo build --release
# Local inference (Ollama): ollama serve && ollama pull qwen2.5:14b
# CLI: cargo run -- --chump "Hello"
# Discord: DISCORD_TOKEN=... cargo run -- --discord
```

Full run options: `./run-discord.sh` or `./run-local.sh` (Ollama + Qwen 2.5 14B by default), `./run-discord-ollama.sh` (same with preflight check), `./run-best.sh` (vLLM-MLX on 8000 if you set OPENAI_API_BASE). See [docs/OPERATIONS.md](docs/OPERATIONS.md) and [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md).

## What Chump has

- **Core:** `run_cli` (allowlist/blocklist, timeout, output cap), `memory` (SQLite FTS5 + optional semantic RRF), `calculator`, optional `wasm_calc`, `delegate` (summarize/extract), `web_search` (Tavily).
- **Repo:** When `CHUMP_REPO` or `CHUMP_HOME` is set: `read_file`, `list_dir`, `write_file`, `edit_file`; optional `git_commit`/`git_push`, `gh_*` (issues, PRs), `diff_review` (self-audit of uncommitted diff).
- **Brain:** Optional `ego` (inner state), `episode` (event log), `task` (queue), `schedule` (alarms: 4h/2d/30m), `memory_brain` (wiki under CHUMP_BRAIN_PATH), `notify` (DM owner). Soul extends with continuity/agency when state DB is available.

## Env (summary)

| Env                         | Purpose                                         |
| --------------------------- | ----------------------------------------------- |
| `OPENAI_API_BASE`           | Model server (e.g. `http://localhost:8000/v1`)  |
| `OPENAI_API_KEY`            | `not-needed` for local; real key for OpenAI     |
| `OPENAI_MODEL`              | Model name (`default` for single-model server)  |
| `DISCORD_TOKEN`             | Bot token (Discord mode)                        |
| `CHUMP_REPO` / `CHUMP_HOME` | Repo path for read_file, edit_file, run_cli cwd |
| `CHUMP_DELEGATE`            | `1` = delegate tool                             |
| `TAVILY_API_KEY`            | Web search (optional)                           |
| `CHUMP_READY_DM_USER_ID`    | Discord user ID for ready DM + notify target    |
| `CHUMP_BRAIN_PATH`          | Brain wiki root (default `chump-brain`)         |

Copy `.env.example` to `.env` and set secrets. More in [docs/OPERATIONS.md](docs/OPERATIONS.md) and [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

## Docs

| Doc                                     | Contents                                             |
| --------------------------------------- | ---------------------------------------------------- |
| [docs/README.md](docs/README.md)        | Index                                                |
| [ARCHITECTURE.md](docs/ARCHITECTURE.md) | Design, tools, brain, soul                           |
| [OPERATIONS.md](docs/OPERATIONS.md)     | Run, serve, Discord, heartbeat, env, troubleshooting |
| [CHUMP_BRAIN.md](docs/CHUMP_BRAIN.md)   | State, episodes, ego, memory_brain setup             |
| [WISHLIST.md](docs/WISHLIST.md)         | Implemented + backlog (schedule, diff_review, etc.)  |

## Tests

```bash
cargo test
./scripts/check.sh   # build, test, clippy
```
