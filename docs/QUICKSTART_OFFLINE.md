---
doc_tag: canonical
owner_gap: PRODUCT-375
last_audited: 2026-11-27
---

# Offline Local Models Quickstart

> **Goal:** Run Chump 100% offline on **macOS, Linux, or Windows** against a local model server (`Ollama`, `LM Studio`, `llama.cpp`, or `vLLM`)—zero cloud API keys, zero telemetry, zero token bills.
> **Time:** ~10 minutes (mostly downloading model weights once).

---

## Step 1 — Install Chump

Choose the prebuilt installer for your OS (or build from source with Cargo):

```bash
# macOS (Homebrew)
brew tap repairman29/chump && brew install chump

# Linux (x86_64 & aarch64)
curl --proto '=https' --tlsv1.2 -LsSf \
  https://github.com/repairman29/chump/releases/latest/download/chump-installer.sh | sh

# Windows (PowerShell)
powershell -ExecutionPolicy ByPass -c "irm https://github.com/repairman29/chump/releases/latest/download/chump-installer.ps1 | iex"
```

Verify the binary:

```bash
chump --version
```

---

## Step 2 — Start a Local OpenAI-Compatible Model Server

[Ollama](https://ollama.com/) provides a single-command OpenAI-compatible server on macOS, Linux, and Windows (`http://127.0.0.1:11434/v1`):

```bash
# Start Ollama (if not already running as a desktop/system service)
ollama serve &

# Pull a coding model sized for your RAM:
ollama pull qwen2.5-coder:7b     # Recommended for 16 GB RAM (~4.7 GB download)
# 8 GB RAM:     ollama pull qwen2.5-coder:3b
# 24–32 GB RAM: ollama pull qwen2.5-coder:14b
# 48+ GB RAM:   ollama pull qwen2.5-coder:32b
```

> **Using LM Studio, llama.cpp, or vLLM instead?** Any local server that exposes `/v1/chat/completions` works identically:
> - **LM Studio:** `http://127.0.0.1:1234/v1`
> - **llama-server (`llama.cpp`):** `http://127.0.0.1:8080/v1`
> - **vLLM:** `http://127.0.0.1:8000/v1`

---

## Step 3 — Configure `~/.chump/config.toml` for Air-Gap Local Routing

Initialize `~/.chump/config.toml` (`%USERPROFILE%\.chump\config.toml` on Windows) and configure your local slot:

```bash
chump config init
```

Edit `~/.chump/config.toml`:

```toml
[auth]
mode = "auto"

[fleet]
mode = "supervised"
desired_workers = 1
harness = "chump-local"
disk_floor_gb = 5.0
auto_merge = false

[web]
bind_addr = "127.0.0.1"
port = 3847

[[providers]]
name = "ollama-local"
enabled = true
tier = "local"
base_url = "http://127.0.0.1:11434/v1"
model = "qwen2.5-coder:7b"
priority = 10
```

Validate the schema:

```bash
chump config validate
```

To enforce strict air-gap mode (disabling outbound web-search and URL-fetch tools even if keys exist in your shell environment), set `CHUMP_AIR_GAP_MODE=1` in `[settings]` or your shell.

---

## Step 4 — Verify a Local Completion

Run a single prompt through your local model:

```bash
OPENAI_API_BASE=http://127.0.0.1:11434/v1 \
OPENAI_API_KEY=ollama \
OPENAI_MODEL=qwen2.5-coder:7b \
chump --once "Reply in one sentence confirming local inference is online."
```

---

## Step 5 — Coordinate Tasks Locally in Any Git Repo

Inside any git repository on your machine:

```bash
# 1. Initialize .chump/state.db and install Rust pre-commit hooks
chump init --yes
chump hook install

# 2. Reserve and claim your first local task
chump gap reserve --domain DEMO --title "Add unit tests for config parser" --effort s
chump claim DEMO-001 --role target --paths "tests/**"

# 3. Inspect queue & cockpit in your browser (100% localhost)
chump --web --port 3847
```

---

## Hybrid Option: Mixing Local Models with Cloud Failover

When you are back on a network and want cloud escalation for large architectural refactors while keeping `$0` local Ollama for routine work, add cloud or subscription credentials alongside your local slot:

| Lane | Credential / Setting | Typical Role |
|------|----------------------|--------------|
| **Subscription OAuth** | `CLAUDE_CODE_OAUTH_TOKEN` or signed-in CLI credentials (`[auth] mode = "auto"`) | Frontier coding & multi-file review |
| **Cloud API Slot** | `[[providers]]` with `api_key_env = "GEMINI_API_KEY"` / `"ANTHROPIC_API_KEY"` | Burst capacity with RPM headroom & RPD caps |
| **Local GPU Slot** | `[[providers]]` with `tier = "local"` (`127.0.0.1:11434/v1`) | Zero-cost floor and offline continuity |

---

## Troubleshooting

| Symptom | Fix |
|---------|-----|
| `connection refused` on `127.0.0.1:11434` | Start `ollama serve` (or launch the Ollama desktop app) and verify `curl http://127.0.0.1:11434/v1/models` |
| `model not found` | Run `ollama list` and make sure `model` in `config.toml` matches the exact tag pulled |
| Slow first reply (10–25s) | Normal cold-load into RAM/VRAM; set `OLLAMA_KEEP_ALIVE=30m` so weights stay warm between turns |
| `chump: command not found` | Ensure `~/.cargo/bin` or `~/.local/bin` (macOS/Linux) or `%USERPROFILE%\.cargo\bin` (Windows) is on `PATH` |

---

## Next Steps

- **Clean-machine verification:** [5-Minute Clean Setup](process/EXTERNAL_GOLDEN_PATH.md)
- **Hardware sizing & `mistral.rs`:** [Hardware & RAM Profiles](operations/INFERENCE_PROFILES.md)
- **Multi-agent leases & hooks:** [File Leases & Worktrees](process/AGENT_COORDINATION.md)
