---
doc_tag: canonical
owner_gap: PRODUCT-147
last_audited: 2026-11-26
---

# Chump v1.0 Documentation

**Chump** is a local-first Rust multi-agent coordinator, pre-commit file-lease firewall, and 40-slot LLM failover router for **macOS, Linux, and Windows**. Bring the coding agents you already use (`Claude Code`, `Codex CLI`, `OpenCode`, `Aider`, `goose`, or local `Ollama` / `vLLM`) and run multiple parallel sessions on one repository without overwritten files or runaway API spend.

- **Product Overview & Interactive Tools:** [repairman29.github.io/chump](https://repairman29.github.io/chump/)
- **Source Repository:** [github.com/repairman29/chump](https://github.com/repairman29/chump)

---

## 60-Second Quickstart

```bash
# 1. Install Chump (macOS Homebrew, Linux POSIX installer, or Cargo)
brew tap repairman29/chump && brew install chump
# Linux:   curl --proto '=https' --tlsv1.2 -LsSf https://github.com/repairman29/chump/releases/latest/download/chump-installer.sh | sh
# Windows: cargo install --git https://github.com/repairman29/chump chump --locked

# 2. Scaffold & validate ~/.chump/config.toml (%USERPROFILE%\.chump\config.toml on Windows)
chump config init
chump config validate

# 3. Install sub-2ms Rust pre-commit lease & secret guards in your git repository
chump hook install
chump hook status

# 4. Start the local supervisor or operator cockpit
chump service install && chump up
chump --web --port 3847
```

---

## Start Here

| Guide | What You Will Learn |
|-------|---------------------|
| [USER_GUIDE.md](USER_GUIDE.md) | Everyday workflows, parallel agent coordination, model tiers, and troubleshooting |
| [QUICKSTART_OFFLINE.md](QUICKSTART_OFFLINE.md) | Running Chump 100% offline against local Ollama, LM Studio, llama.cpp, or vLLM |
| [EXTERNAL_GOLDEN_PATH.md](process/EXTERNAL_GOLDEN_PATH.md) | End-to-end clean-machine setup and verification walkthrough |
| [PWA_USER_GUIDE.md](PWA_USER_GUIDE.md) | Using the local Warm-Stone web cockpit (`/v2/`): task queue, leases, and health tiles |
| [CLI_FLAGS.md](CLI_FLAGS.md) & [CLI_EXIT_CODES.md](CLI_EXIT_CODES.md) | Complete CLI subcommand flags and deterministic exit-code contracts |

---

## Multi-Agent Coordination & Git Firewall

| Reference | Purpose |
|-----------|---------|
| [AGENT_COORDINATION.md](process/AGENT_COORDINATION.md) | Atomic path/symbol leases, isolated git worktrees, `ambient.jsonl`, and pre-commit guards |
| [CHUMP_CURSOR_FLEET.md](process/CHUMP_CURSOR_FLEET.md) | Running Cursor, Claude Code, and terminal agents side-by-side without file collisions |
| [CANONICAL_SERVICES.md](process/CANONICAL_SERVICES.md) | Shared LLM cascade (`chump llm-complete`) and repository service boundaries |
| [OPERATOR_PLAYBOOK.md](process/OPERATOR_PLAYBOOK.md) | Local SQLite GitHub cache, webhook setup, rate-limit protection, and recovery |

---

## Model Routing, Local Inference & Operations

| Reference | Purpose |
|-----------|---------|
| [PROVIDER_CASCADE.md](architecture/PROVIDER_CASCADE.md) | Configuring subscription OAuth, up to 40 API-key slots, RPM headroom, and failover |
| [EXECUTION_BACKENDS.md](architecture/EXECUTION_BACKENDS.md) | Comparing Ollama, vLLM, mistral.rs, and hosted OpenAI-compatible endpoints |
| [INFERENCE_PROFILES.md](operations/INFERENCE_PROFILES.md) | Recommended local and hybrid model profiles by machine RAM (8 GB to 64+ GB) |
| [INFERENCE_STABILITY.md](operations/INFERENCE_STABILITY.md) | Preventing timeouts, OOM swap thrashing, and upstream HTTP 429 stalls |
| [OPERATIONS.md](operations/OPERATIONS.md) | Native `launchd`, `systemd --user`, and Windows Task Scheduler (`ChumpDaemon`) supervision |
| [STORAGE_AND_ARCHIVE.md](operations/STORAGE_AND_ARCHIVE.md) | Worktree garbage collection, target-directory hygiene, and SQLite maintenance |

---

## Architecture & Editor Integrations

| Reference | Purpose |
|-----------|---------|
| [ARCHITECTURE.md](architecture/ARCHITECTURE.md) | Workspace crate architecture (`chump-pal`, `chump-config`, `chump-git-hooks`, `chump-ship`, `chumpd`) |
| [RUST_MODULE_MAP.md](architecture/RUST_MODULE_MAP.md) | Crate-by-crate responsibilities across the 60-package Rust 2021 workspace |
| [ACP.md](architecture/ACP.md) | Agent Client Protocol (`chump --acp`) integration for Zed, JetBrains, and ACP editors |
| [WEB_API_REFERENCE.md](api/WEB_API_REFERENCE.md) | Local HTTP & SSE endpoints served by `chump --web` |
| [ROADMAP.md](ROADMAP.md) & [NORTH_STAR.md](strategy/NORTH_STAR.md) | Product roadmap, four engineering pillars, and long-term architectural direction |
