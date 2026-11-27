---
doc_tag: canonical
owner_gap: PRODUCT-375
last_audited: 2026-11-27
---

# 5-Minute Clean Setup (External Golden Path)

This guide walks any developer on a clean **macOS, Linux, or Windows** machine from zero to a verified Chump `v1.0` installation: configuration validated, pre-commit lease firewall installed, web cockpit live on `127.0.0.1`, and health endpoints green.

---

## Prerequisites

- **OS:** macOS 13+ (Apple Silicon or Intel), Linux (`x86_64` or `aarch64`), or Windows 10/11 (`x86_64`)
- **Git:** `git` 2.30+ on `PATH` (for worktrees and pre-commit hooks)
- **Model backend (pick any one):**
  - Local [Ollama](https://ollama.com/), LM Studio, `llama.cpp`, or `vLLM` (no API key needed), **or**
  - Any OpenAI/Anthropic/Gemini API key or signed-in CLI harness (`claude`, `codex`, `opencode`, `aider`)

---

## 1. Install `chump`

### Option A — Prebuilt Release Binary (~25 seconds)

```bash
# macOS (Homebrew)
brew tap repairman29/chump && brew install chump

# Linux (POSIX shell installer)
curl --proto '=https' --tlsv1.2 -LsSf \
  https://github.com/repairman29/chump/releases/latest/download/chump-installer.sh | sh

# Windows (PowerShell)
powershell -ExecutionPolicy ByPass -c "irm https://github.com/repairman29/chump/releases/latest/download/chump-installer.ps1 | iex"
```

### Option B — Build from Source with Rust Cargo

```bash
git clone https://github.com/repairman29/chump.git
cd chump
cargo build --release --bin chump
```

> **Automated no-model smoke check (source checkouts):** Run `./scripts/ci/verify-external-golden-path.sh` (and optional timing helper `./scripts/ci/golden-path-timing.sh`) to verify binary compilation, config validation, and static assets without requiring a live model key.

---

## 2. Initialize Configuration & Repository Guards

Inside any git repository you want Chump to coordinate:

```bash
# 1. Create ~/.chump/config.toml (0600 permissions on Unix) and validate schema
chump config init
chump config validate

# 2. Initialize .chump/state.db (SQLite WAL) in the target repository
chump init --yes

# 3. Install native Rust pre-commit & pre-push guards
chump hook install
chump hook status
```

Expected output from `chump hook status`: both `pre-commit` and `pre-push` hooks report `installed` and active.

---

## 3. Connect Your Model Backend

Edit `~/.chump/config.toml` (`chump config path` prints the exact file path for your OS):

- **Local Ollama (`$0` offline):** ensure `ollama serve` is running (`ollama pull qwen2.5-coder:7b`) and keep a `tier = "local"` `[[providers]]` entry pointing at `http://127.0.0.1:11434/v1`.
- **Cloud API or Subscription OAuth:** set `GEMINI_API_KEY`, `ANTHROPIC_API_KEY`, `OPENAI_API_KEY`, or `CLAUDE_CODE_OAUTH_TOKEN` in your environment and reference the variable name via `api_key_env` in `[[providers]]` (secrets stay in env vars or OS keychains, never hardcoded in `config.toml`).

Re-validate after editing:

```bash
chump config validate
```

---

## 4. Launch the Web Cockpit & Run Preflight

Start the local web server in one terminal:

```bash
chump --web --port 3847
```

Open **http://127.0.0.1:3847/v2/** in your browser to view the Sovereign Operator Cockpit, or **http://127.0.0.1:3847/site/** to use the interactive Config Doctor and Fleet Simulator locally.

### Preflight Verification

Verify health and inference readiness from a second terminal:

```bash
curl -fsS http://127.0.0.1:3847/api/health
curl -fsS http://127.0.0.1:3847/api/stack-status
```

- `GET /api/health` returns `{"status":"ok","service":"chump-web","binary_version":"1.0.0",...}`.
- `GET /api/stack-status` reports `inference.models_reachable: true` when your configured local or cascade model endpoint responds cleanly.
- Before pushing code changes in a repository managed by Chump, run `chump preflight` to execute formatting, `clippy -D warnings`, compile checks, and scoped tests locally.

---

## 5. Optional: Enable Background Supervision (`chumpd`)

To keep worker pools, OAuth credential refresh, and expired-lease reaping running automatically in the background:

```bash
chump service install
chump up
chump service status
```

See [Daemon & Service Operations](../operations/OPERATIONS.md) for `LaunchAgents` (macOS), `systemd --user` (Linux), and `ChumpDaemon` (Windows) details.

---

## Next Steps

- [User Guide](../USER_GUIDE.md) — Reserve gaps, claim worktrees, and ship PRs
- [File Leases & Worktrees](AGENT_COORDINATION.md) — How parallel sessions stay collision-free
- [Provider Cascade & OAuth](../architecture/PROVIDER_CASCADE.md) — Multi-slot routing and rate-limit protection
- [Optional Chat Adapters](../architecture/MESSAGING_ADAPTERS.md) — Opt-in Slack, Telegram, or Discord notifications
