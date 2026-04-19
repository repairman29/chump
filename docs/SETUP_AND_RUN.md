# Setup and Run

Quick-start reference. For the full first-install walkthrough, see [EXTERNAL_GOLDEN_PATH.md](EXTERNAL_GOLDEN_PATH.md) (target: 30 min from cold clone to working PWA).

## Prerequisites

| Requirement | Notes |
|-------------|-------|
| **Rust** (stable) | `rustup toolchain install stable` |
| **Ollama** | [ollama.com](https://ollama.com) — local OpenAI-compatible server |
| **Git** | Standard |
| **macOS or Linux** | Windows via WSL works but is not regularly tested |

## Minimal first-run (Ollama + web PWA)

```bash
git clone <repo-url> chump && cd chump

# 1. Create .env with Ollama defaults
./scripts/setup-local.sh

# 2. Pull a model
ollama pull qwen2.5:14b   # ~8GB — adjust for your VRAM

# 3. Build and start
cargo build --bin chump   # first build: 3–5 min
./run-web.sh              # starts web server on :3000

# 4. Verify
./scripts/chump-preflight.sh
```

Open `http://localhost:3000` in a browser. If preflight passes, you have a working agent.

## Minimal .env

```bash
OPENAI_API_BASE=http://localhost:11434/v1
OPENAI_API_KEY=ollama
OPENAI_MODEL=qwen2.5:14b
```

Leave `DISCORD_TOKEN`, `TAVILY_API_KEY`, and cascade provider keys commented out for the first session. Add them incrementally; see [INFERENCE_PROFILES.md](INFERENCE_PROFILES.md) for switching profiles without breaking the running config.

## CLI mode

```bash
./run-local.sh           # starts CLI, no server
# or:
cargo run --bin chump    # same, with auto-rebuild
```

## Discord mode

```bash
# After setting DISCORD_TOKEN in .env:
./run-discord.sh
# Verify: ./scripts/check-discord-preflight.sh
```

See [OPERATIONS.md](OPERATIONS.md#discord) for bot invite, Message Content Intent, and multi-guild notes.

## Desktop app (macOS)

```bash
cargo build -p chump-desktop
cargo run --bin chump -- --desktop
# Or create a Dock shortcut:
./scripts/macos-cowork-dock-app.sh
```

## Release build

```bash
cargo build --release --bin chump
CHUMP_USE_RELEASE=1 ./run-web.sh
```

## Health checks

| Check | Command |
|-------|---------|
| HTTP health | `curl -s http://localhost:3000/api/health \| jq .status` |
| Full preflight | `./scripts/chump-preflight.sh` (or `chump --preflight`) |
| Stack status | `curl -s http://localhost:3000/api/stack-status \| jq .` |
| Config summary | `cargo run --bin chump -- --check-config` |

## See Also

- [External Golden Path](EXTERNAL_GOLDEN_PATH.md) — detailed first-install guide with troubleshooting
- [Operations](OPERATIONS.md) — full env reference, heartbeat, fleet, roles
- [Inference Profiles](INFERENCE_PROFILES.md) — switching between Ollama / vLLM-MLX / provider cascade
- [FLEET_ROLES.md](FLEET_ROLES.md) — adding Pixel/Mabel after first success
