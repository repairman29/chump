# Setup and run

This doc spells out where to run from, how models are chosen, and how this repo relates to the old layout.

## This repo is the only Chump repo

- **Canonical repo:** [github.com/repairman29/chump](https://github.com/repairman29/chump). All Chump development and runs use this repo.
- **Clone name:** Often `chump-repo` or just `chump`. The directory that contains `Cargo.toml`, `run-discord.sh`, and `run-local.sh` is the **repo root**.

## Run everything from repo root

All commands and scripts are intended to be run **from the Chump repo root**. If your clone is `chump-repo`, run:

```bash
cd chump-repo
```

Then:

- **Discord:** `./run-discord.sh` or `./run-discord-ollama.sh`
- **CLI:** `./run-local.sh --chump "Hello"` or `cargo run -- --chump "Hello"`
- **Preflight:** `./scripts/check-discord-preflight.sh`
- **Scripts in `scripts/`:** e.g. `./scripts/farmer-brown.sh` — they resolve the repo root via `CHUMP_HOME` or `$(dirname "$0")/..`, so run them from repo root too (e.g. `./scripts/check-discord-preflight.sh`).

The run scripts (`run-discord.sh`, `run-local.sh`, `run-discord-ollama.sh`) do `cd "$(dirname "$0")"`, so you can also invoke them by full path (e.g. `/path/to/chump-repo/run-local.sh --chump "Hi"`); they will still run in the repo directory.

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

- **Location:** `ChumpMenu/` inside this repo. Build the app from this repo (e.g. use the ChumpMenu build script from repo root).
- **Default repo path:** The app’s default “Chump repo path” points at this repo (e.g. `…/Maclawd/chump-repo` or your clone path). Use **Set Chump repo path…** in the menu if your clone lives elsewhere.
- **Binary:** The app looks for `target/release/rust-agent` (or `target/debug/rust-agent`) inside the chosen repo path. The binary name comes from `Cargo.toml` (`name = "rust-agent"`).
- **If you used to run from somewhere else:** Rebuild ChumpMenu from **this** repo and use the new app. Old builds that pointed at a removed `rust-agent` directory will show “Not found: run-discord.sh” until the path is set to this repo or the app is rebuilt from here.

## Migration from rust-agent / Maclawd layout

- **Retired:** A separate `rust-agent` tree (e.g. under a Maclawd or other parent) is no longer used. All run scripts, docs, and the menu app assume a single Chump repo (this one).
- **Paths in docs and plists:** Placeholders like `/path/to/chump-repo` or “repo path” mean this repo’s root. Replace with your actual path when configuring launchd, SSH commands, or ChumpMenu.
- **Nothing was broken by deleting the old tree:** As long as you run from this repo and (if you use it) point ChumpMenu at this repo (or rebuild the app from here), everything works. The only failure mode is using an old ChumpMenu build that still points at the removed directory.

## Quick checklist

1. Clone or use this repo; `cd` to its root.
2. `cp .env.example .env`; set `DISCORD_TOKEN` (and optionally `TAVILY_API_KEY`, etc.).
3. Start Ollama: `ollama serve && ollama pull qwen2.5:14b`.
4. Optional: `./scripts/check-discord-preflight.sh` to verify token, no duplicate bot, and model server.
5. Discord: `./run-discord.sh` or `./run-discord-ollama.sh`. CLI: `./run-local.sh --chump "Hello"`.
6. If you use ChumpMenu: set its repo path to this repo (or rebuild the app from this repo).

See [OPERATIONS.md](OPERATIONS.md) for full run/serve options, env reference, and troubleshooting.
