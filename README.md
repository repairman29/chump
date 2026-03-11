# Chump

**Canonical repo:** [github.com/repairman29/chump](https://github.com/repairman29/chump). Local AI agent (Rust + [AxonerAI](https://crates.io/crates/axonerai)) talking to an OpenAI-compatible API. Discord bot + CLI; tools for memory, repo, GitHub, tasks, schedule, and self-audit. **Ollama by default (qwen2.5:14b); no Python in the agent runtime.**

**Quick start:** Clone to `~/Projects/Chump` → `./scripts/setup-local.sh` → set `DISCORD_TOKEN` in `.env` → `ollama serve && ollama pull qwen2.5:14b` → `./run-discord.sh`. Enable **Message Content Intent** in the Discord Developer Portal (Bot). See [docs/SETUP_QUICK.md](docs/SETUP_QUICK.md).

## Build and run

**Run everything from this repo’s root** (the directory containing `Cargo.toml`, `run-discord.sh`, and `run-local.sh`). Typical clone: `~/Projects/Chump`.

```bash
cargo build --release
# Local inference (Ollama): ollama serve && ollama pull qwen2.5:14b
# CLI: ./run-local.sh --chump "Hello"
# Discord: ./run-discord.sh   (set DISCORD_TOKEN in .env)
```

**First time?** Run `./scripts/setup-local.sh`, then follow [docs/SETUP_QUICK.md](docs/SETUP_QUICK.md). Full run options: `./run-discord.sh`, `./run-local.sh` (Ollama + qwen2.5:14b default), `./run-discord-ollama.sh` (with preflight), `./run-best.sh` (vLLM-MLX). See [docs/SETUP_AND_RUN.md](docs/SETUP_AND_RUN.md) and [docs/OPERATIONS.md](docs/OPERATIONS.md). Discord broken? [docs/DISCORD_TROUBLESHOOTING.md](docs/DISCORD_TROUBLESHOOTING.md).

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

| Doc | Contents |
| --- | -------- |
| [docs/README.md](docs/README.md) | Index |
| [SETUP_QUICK.md](docs/SETUP_QUICK.md) | One-time setup: Ollama, Discord, autonomy, ChumpMenu |
| [SETUP_AND_RUN.md](docs/SETUP_AND_RUN.md) | Run from repo root, model selection, ChumpMenu |
| [OPERATIONS.md](docs/OPERATIONS.md) | Run/serve, Discord, heartbeat, env, troubleshooting |
| [DISCORD_TROUBLESHOOTING.md](docs/DISCORD_TROUBLESHOOTING.md) | Message Content Intent, token, errors in reply |
| [OLLAMA_SPEED.md](docs/OLLAMA_SPEED.md) | Speed tuning: context, keep_alive, parallel, model choice |
| [ARCHITECTURE.md](docs/ARCHITECTURE.md) | Design, tools, brain, soul |
| [CHUMP_BRAIN.md](docs/CHUMP_BRAIN.md) | State, episodes, ego, memory_brain setup |
| [WISHLIST.md](docs/WISHLIST.md) | Implemented + backlog |

## Tests

```bash
cargo test
./scripts/check.sh   # build, test, clippy
```
