# Setup and run

This doc spells out where to run from, how models are chosen, and how this repo relates to the old layout.

## This repo is the only Chump repo

- **Canonical repo:** [github.com/repairman29/chump](https://github.com/repairman29/chump). All Chump development and runs use this repo.
- **Clone name:** Often `Chump` (e.g. `~/Projects/Chump`). The directory that contains `Cargo.toml`, `run-discord.sh`, and `run-local.sh` is the **repo root**.

## Run everything from repo root

All commands and scripts are intended to be run **from the Chump repo root**:

```bash
cd ~/Projects/Chump   # or your clone path
```

Then:

- **Discord:** `./run-discord.sh` or `./run-discord-ollama.sh`
- **CLI:** `./run-local.sh --chump "Hello"` or `cargo run -- --chump "Hello"`
- **Preflight:** `./scripts/check-discord-preflight.sh`
- **Scripts in `scripts/`:** e.g. `./scripts/farmer-brown.sh` — they resolve the repo root via `CHUMP_HOME` or `$(dirname "$0")/..`, so run them from repo root too (e.g. `./scripts/check-discord-preflight.sh`).

The run scripts do `cd` into the script directory, so you can invoke them by full path; they will still run in the repo.

## Local inference: Ollama by default

- **Default model server:** Ollama at `http://localhost:11434/v1`.
- **Default model:** `qwen2.5:14b` (set by the run scripts and ChumpMenu for “Send test message”).
- **Setup:** `ollama serve && ollama pull qwen2.5:14b`. No Python in the agent runtime.

The run scripts set:

- `OPENAI_API_BASE` = `http://localhost:11434/v1` (unless overridden by `.env`)
- `OPENAI_API_KEY` = `ollama`
- `OPENAI_MODEL` = `qwen2.5:14b`

Override any of these in `.env` or the environment if you use a different model or server (e.g. vLLM-MLX on 8000).

## How Chump’s model is chosen

- **Source of truth:** Environment variable `OPENAI_MODEL` (and, for the worker, `CHUMP_WORKER_MODEL`).
- **Rust code:** Reads `OPENAI_MODEL`; if unset, defaults to `gpt-5-mini`. The run scripts set it before calling `cargo run`, so you normally get the script default (e.g. `qwen2.5:14b` for Ollama).
- **Override:** Set `OPENAI_MODEL` (and optionally `OPENAI_API_BASE`) in `.env` or when invoking the script (e.g. `OPENAI_MODEL=llama3.2:3b ./run-local.sh --chump "Hi"`).

## Run scripts (summary)

| Script | Purpose |
|--------|--------|
| `./run-discord.sh` | Discord bot. Loads `.env`, sets Ollama defaults, runs `cargo run -- --discord`. |
| `./run-discord-ollama.sh` | Same as above; also checks Ollama is reachable (preflight) and exits with instructions if not. |
| `./run-local.sh` | CLI. Loads `.env`, sets Ollama defaults, runs `cargo run -- "$@"` (e.g. `./run-local.sh --chump "Hello"`). |
| `./run-best.sh` | For vLLM-MLX (8000); set `OPENAI_API_BASE` accordingly. |
| `./scripts/check-discord-preflight.sh` | Checks `.env`, `DISCORD_TOKEN`, no duplicate bot process, and model server (Ollama or `OPENAI_API_BASE`). Run from repo root. |

## ChumpMenu (menu bar app)

- **Location:** `ChumpMenu/` in this repo. Build from repo root: `./scripts/build-chump-menu.sh`.
- **Default repo path:** `~/Projects/Chump`. Use **Set Chump repo path…** in the menu only if your clone is elsewhere.
- **Binary:** The app runs `run-discord.sh` from the chosen repo path and expects `target/release/rust-agent` (or `target/debug/rust-agent`) for “Send test message”.
- **Logs:** Start/Stop write to `logs/discord.log` in the repo path. Errors in replies are logged to `logs/chump.log`; see [DISCORD_TROUBLESHOOTING.md](DISCORD_TROUBLESHOOTING.md).

## Migration from rust-agent / other layouts

- **Single repo:** All run scripts, docs, and ChumpMenu use one Chump repo (this one). No separate `rust-agent` tree.
- **Paths:** In plists and SSH commands, use your repo path (e.g. `~/Projects/Chump`). ChumpMenu default is `~/Projects/Chump`.

## Quick checklist

**Short path:** Run `./scripts/setup-local.sh`, then follow [SETUP_QUICK.md](SETUP_QUICK.md).

1. Clone this repo (e.g. to `~/Projects/Chump`); `cd` to its root.
2. `cp .env.example .env`; set `DISCORD_TOKEN` (and optionally `TAVILY_API_KEY`).
3. Start Ollama: `ollama serve && ollama pull qwen2.5:14b`.
4. Discord preflight: `./scripts/check-discord-preflight.sh`. Then `./run-discord.sh` or `./run-discord-ollama.sh`.
5. CLI: `./run-local.sh --chump "Hello"`.
6. ChumpMenu: build from this repo; default path is `~/Projects/Chump`. Change in menu only if your clone is elsewhere.

Problems? [DISCORD_TROUBLESHOOTING.md](DISCORD_TROUBLESHOOTING.md) · [OPERATIONS.md](OPERATIONS.md)
