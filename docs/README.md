---
doc_tag: canonical
owner_gap: PRODUCT-375
last_audited: 2026-11-27
---

# Chump v1.0 Reference Documentation

**Chump** is a local-first Rust multi-agent coordinator, pre-commit file-lease firewall, and 40-slot LLM failover router for **macOS, Linux, and Windows**. Bring the coding agents you already use (`Claude Code`, `Codex CLI`, `OpenCode`, `Aider`, `goose`, or local `Ollama` / `vLLM`) and run parallel sessions on one repository without overwritten files or runaway API spend.

- **Product Site & Interactive Simulators:** [repairman29.github.io/chump](https://repairman29.github.io/chump/)
- **60-Second Quickstart Card:** [repairman29.github.io/chump/docs](https://repairman29.github.io/chump/docs/)
- **Source Repository & Releases:** [github.com/repairman29/chump](https://github.com/repairman29/chump)

---

## 60-Second Quickstart

```bash
# 1. Install Chump (macOS Homebrew, Linux shell, Windows PowerShell, or Cargo)
brew tap repairman29/chump && brew install chump
# Linux:   curl --proto '=https' --tlsv1.2 -LsSf https://github.com/repairman29/chump/releases/latest/download/chump-installer.sh | sh
# Windows: powershell -ExecutionPolicy ByPass -c "irm https://github.com/repairman29/chump/releases/latest/download/chump-installer.ps1 | iex"
# Source:  cargo install --git https://github.com/repairman29/chump chump --locked

# 2. Scaffold & validate ~/.chump/config.toml (%USERPROFILE%\.chump\config.toml on Windows)
chump config init
chump config validate

# 3. Install sub-2ms Rust pre-commit lease & secret guards in your git repository
chump hook install
chump hook status

# 4. Start the background supervisor or open the local web cockpit
chump service install && chump up
chump --web --port 3847
```

---

## Start Here

| Guide | What You Will Learn |
|-------|---------------------|
| [User Guide](USER_GUIDE.md) | Everyday workflows across macOS, Linux, and Windows, task queues, parallel worktrees, and troubleshooting |
| [5-Minute Clean Setup](process/EXTERNAL_GOLDEN_PATH.md) | Step-by-step clean-machine onboarding and `Preflight` verification |
| [Offline Local Models](QUICKSTART_OFFLINE.md) | Running Chump 100% offline against local Ollama, LM Studio, llama.cpp, or vLLM |
| [Web Cockpit (`/v2/`)](PWA_USER_GUIDE.md) | Using the local browser cockpit: task queue, active leases, model routing, and health telemetry |
| [CLI Flags](CLI_FLAGS.md) & [CLI Exit Codes](CLI_EXIT_CODES.md) | Scriptable CLI flags (`--why`, `--format`, `--quiet`) and deterministic exit codes |

---

## Multi-Agent Coordination & Git Firewall

| Reference | Purpose |
|-----------|---------|
| [File Leases & Worktrees](process/AGENT_COORDINATION.md) | SQLite WAL task registry (`.chump/state.db`), path/symbol leases (`.chump-locks/`), `chump hook`, and `chump ship` |
| [IDE & Terminal Workflows](process/CHUMP_CURSOR_FLEET.md) | Running Cursor, Claude Code, Codex, and terminal agents side-by-side without file collisions |
| [Shared Services](process/CANONICAL_SERVICES.md) | Unified LLM completion routing (`ProviderCascade` and `chump llm-complete`) |

---

## Model Routing, Local Inference & Operations

| Reference | Purpose |
|-----------|---------|
| [Provider Cascade & OAuth](architecture/PROVIDER_CASCADE.md) | Configuring subscription OAuth, up to 40 API-key slots, RPM headroom, and circuit breakers |
| [Execution Backends](architecture/EXECUTION_BACKENDS.md) | Local host execution vs. isolated Docker container and SSH command sandboxes |
| [Hardware & RAM Profiles](operations/INFERENCE_PROFILES.md) | Recommended local and hybrid model configurations by machine RAM (8 GB to 64+ GB) |
| [Inference Stability](operations/INFERENCE_STABILITY.md) | Preventing timeouts, OOM swap thrashing, and upstream HTTP 429 stalls |
| [Daemon & Service Operations](operations/OPERATIONS.md) | Native `LaunchAgents`, `systemd --user`, and Windows Task Scheduler (`ChumpDaemon`) supervision |
| [Storage & Worktree Hygiene](operations/STORAGE_AND_ARCHIVE.md) | Worktree garbage collection, `target/` cache hygiene, and runtime backups |

---

## Architecture & Integrations

| Reference | Purpose |
|-----------|---------|
| [System Architecture](architecture/ARCHITECTURE.md) | Multi-OS Rust control plane (`chump-pal`, `chump-config`, `chump-git-hooks`, `chump-ship`, `chumpd`) |
| [Workspace Module Map](architecture/RUST_MODULE_MAP.md) | Module-by-module responsibilities across the Rust 2021 workspace |
| [Editor Integration (ACP)](architecture/ACP.md) | Agent Client Protocol (`chump --acp`) server for Zed, JetBrains IDEs, and ACP clients |
| [HTTP & SSE API](api/WEB_API_REFERENCE.md) | Local REST and Server-Sent Events endpoints served by `chump --web` |
| [Product Roadmap](ROADMAP.md) | Four engineering pillars, shipped v1.0 foundation, and v1.x milestones |
| [Optional Chat Adapters](architecture/MESSAGING_ADAPTERS.md) | Opt-in Slack, Telegram, and Discord adapters for remote notifications |
