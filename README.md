# Chump

**Canonical repo:** [github.com/repairman29/chump](https://github.com/repairman29/chump). Local AI agent (Rust + [AxonerAI](https://crates.io/crates/axonerai)) talking to an OpenAI-compatible API. Discord bot + CLI; tools for memory, repo, GitHub, tasks, schedule, and self-audit. **Ollama by default (qwen2.5:14b); no Python in the agent runtime.** Optional **provider cascade** (Groq, Cerebras, etc.) for cloud + local fallback. **Mabel** is the Pixel companion: same binary, optional cascade for faster responses (see [docs/PROVIDER_CASCADE.md](docs/PROVIDER_CASCADE.md)).

**Quick start:** Clone to `~/Projects/Chump` → `./scripts/setup-local.sh` → set `DISCORD_TOKEN` in `.env` → `ollama serve && ollama pull qwen2.5:14b` → `./run-discord.sh`. Enable **Message Content Intent** in the Discord Developer Portal (Bot). See [docs/SETUP_QUICK.md](docs/SETUP_QUICK.md). Optional: for **cascade** set provider keys in `.env`; for **Mabel on Pixel** run `apply-mabel-badass-env.sh` with `MAC_ENV` (or after `deploy-all-to-pixel.sh`) so she gets cascade — [docs/PROVIDER_CASCADE.md](docs/PROVIDER_CASCADE.md).

## Build and run

**Run everything from this repo’s root** (the directory containing `Cargo.toml`, `run-discord.sh`, and `run-local.sh`). Typical clone: `~/Projects/Chump`. Build produces `target/release/chump` (or `rust-agent`).

```bash
cargo build --release
# Local inference (Ollama): ollama serve && ollama pull qwen2.5:14b
# CLI: ./run-local.sh --chump "Hello"
# Discord: ./run-discord.sh   (set DISCORD_TOKEN in .env)
# PWA: ./run-web.sh
# Product-shipping heartbeat: ./scripts/heartbeat-ship.sh
```

**First time?** Run `./scripts/setup-local.sh`, then follow [docs/SETUP_QUICK.md](docs/SETUP_QUICK.md). Full run options: `./run-discord.sh`, `./run-local.sh` (Ollama + qwen2.5:14b default), `./run-discord-ollama.sh` (with preflight), `./run-web.sh` (PWA). See [docs/SETUP_AND_RUN.md](docs/SETUP_AND_RUN.md) and [docs/OPERATIONS.md](docs/OPERATIONS.md). Discord broken? [docs/DISCORD_TROUBLESHOOTING.md](docs/DISCORD_TROUBLESHOOTING.md).

## What Chump has

- **Core:** `run_cli` (allowlist/blocklist, timeout, output cap), `memory` (SQLite FTS5 + optional semantic RRF), `calculator`, optional `wasm_calc`, `delegate` (summarize/extract), `web_search` (Tavily).
- **Provider cascade:** Cloud slots (Groq, Cerebras, Mistral, etc.) + local fallback; enable with `CHUMP_CASCADE_ENABLED=1` and provider keys. [docs/PROVIDER_CASCADE.md](docs/PROVIDER_CASCADE.md).
- **Mabel:** Pixel companion — same binary, `CHUMP_MABEL=1`; optional cascade via `apply-mabel-badass-env.sh` (MAC_ENV or ~/chump/.env.mac) for faster responses.
- **Repo:** When `CHUMP_REPO` or `CHUMP_HOME` is set: `read_file`, `list_dir`, `write_file`, `edit_file`, `run_battle_qa` (smoke + structured result for self-heal); optional `git_commit`/`git_push`, `gh_*` (issues, PRs), `diff_review` (self-audit of uncommitted diff).
- **Brain:** Optional `ego` (inner state), `episode` (event log), `task` (queue), `schedule` (alarms: 4h/2d/30m), `memory_brain` (wiki under CHUMP_BRAIN_PATH), `notify` (DM owner). Soul extends with continuity/agency when state DB is available.

## Env (summary)

| Env                         | Purpose                                         |
| --------------------------- | ----------------------------------------------- |
| `OPENAI_API_BASE`           | Model server (default `http://localhost:11434/v1` for Ollama) |
| `OPENAI_API_KEY`            | `not-needed` for local; real key for OpenAI     |
| `OPENAI_MODEL`              | Model name (`default` for single-model server)  |
| `DISCORD_TOKEN`             | Bot token (Discord mode)                        |
| `CHUMP_REPO` / `CHUMP_HOME` | Repo path for read_file, edit_file, run_cli cwd |
| `CHUMP_CASCADE_ENABLED`     | `1` = use provider cascade (cloud + local); [docs/PROVIDER_CASCADE.md](docs/PROVIDER_CASCADE.md) |
| `CHUMP_MABEL`               | `1` = Mabel/companion mode (short tool routing)  |
| `CHUMP_BRAIN_AUTOLOAD`      | Comma-separated brain files to inject (e.g. `self.md,mabel/dossier.md,research/latest.md`) |
| `CHUMP_DELEGATE`            | `1` = delegate tool                             |
| `TAVILY_API_KEY`            | Web search (optional)                           |
| `CHUMP_READY_DM_USER_ID`    | Discord user ID for ready DM + notify target    |
| `CHUMP_BRAIN_PATH`          | Brain wiki root (default `chump-brain`)         |

Copy `.env.example` to `.env` and set secrets. More in [docs/OPERATIONS.md](docs/OPERATIONS.md), [docs/PROVIDER_CASCADE.md](docs/PROVIDER_CASCADE.md), and [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

## Docs

**Full index:** [docs/README.md](docs/README.md) — start there. Key entries:

| Doc | Contents |
| --- | -------- |
| [docs/ROADMAP.md](docs/ROADMAP.md) | What to work on (heartbeat + Cursor read first) |
| [docs/CHUMP_PROJECT_BRIEF.md](docs/CHUMP_PROJECT_BRIEF.md) | Focus and conventions |
| [docs/README.md](docs/README.md) | Full doc index (run, roadmaps, brain, Mabel, reference) |
| [docs/SETUP_QUICK.md](docs/SETUP_QUICK.md) | One-time setup |
| [docs/OPERATIONS.md](docs/OPERATIONS.md) | Run, Discord, heartbeat, env, roles |
| [docs/PROVIDER_CASCADE.md](docs/PROVIDER_CASCADE.md) | Cascade slots, keys, Mabel on Pixel |
| [docs/FLEET_ROLES.md](docs/FLEET_ROLES.md) | Fleet expansion (Chump + Mabel + Scout) |
| [docs/CHUMP_BRAIN.md](docs/CHUMP_BRAIN.md) | Brain, state, episodes, directory layout |
| [docs/BATTLE_QA.md](docs/BATTLE_QA.md) | QA job; [self-heal](docs/BATTLE_QA_SELF_FIX.md) |
| [docs/WISHLIST.md](docs/WISHLIST.md) | Backlog |

## Tests

```bash
cargo test
./scripts/check.sh   # build, test, clippy
```
