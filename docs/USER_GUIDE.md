---
doc_tag: canonical
owner_gap: PRODUCT-375
last_audited: 2026-11-27
---

# Chump User Guide

> **Audience:** Developers and engineering teams running one or more AI coding agents on **macOS, Linux, or Windows**—using existing subscriptions, API keys, or `$0` local models.
>
> **Prerequisite:** Install `chump` via the [5-Minute Clean Setup](process/EXTERNAL_GOLDEN_PATH.md) or [Offline Local Models](QUICKSTART_OFFLINE.md) guide and confirm `chump --version` prints `1.0.0` (or newer).

---

## 1. Core Concepts

| Term | What It Means |
|------|---------------|
| **Gap** | A tracked unit of engineering work stored in `.chump/state.db` (SQLite WAL) so parallel agents never pick duplicate tasks. |
| **Lease** | A TTL-bounded JSON lock file in `.chump-locks/<session>.json` declaring which file globs (`crates/auth/**`) or symbols (`src/lib.rs::parse`) an agent owns. |
| **Worktree** | An isolated linked git checkout created automatically by `chump claim` so each agent compiles and edits without disturbing your main working tree. |
| **Hook Firewall** | Native Rust `pre-commit` and `pre-push` hooks (`chump hook install`) that reject cross-session lease collisions, secret leaks, and unformatted code in `<2ms`. |
| **Provider Cascade** | Up to 40 prioritized model slots in `~/.chump/config.toml` combining subscription OAuth, cloud APIs, CLI harnesses, and local GPU endpoints. |
| **Ship Pipeline** | `chump ship`, which rebases clean branches, opens pull requests, and blocks `--auto-merge` whenever `.github/workflows/*` or git hooks are modified. |

---

## 2. Configure Once (`~/.chump/config.toml`)

Generate a starter configuration file (`~/.chump/config.toml` on macOS/Linux, `%USERPROFILE%\.chump\config.toml` on Windows) and verify it:

```bash
chump config init
chump config path
chump config validate
```

You can combine up to four model and execution lanes in one file:

```toml
[auth]
mode = "auto"                # Auto-detects Claude OAuth credentials or API keys

[fleet]
mode = "grind"               # "grind" | "supervised" | "off"
desired_workers = 2
harness = "claude"           # "claude" | "opencode" | "codex" | "aider" | "chump-local"
disk_floor_gb = 5.0
auto_merge = false

[web]
bind_addr = "127.0.0.1"
port = 3847

[[providers]]
name = "gemini-primary"
enabled = true
tier = "cloud"
base_url = "https://generativelanguage.googleapis.com/v1beta/openai"
api_key_env = "GEMINI_API_KEY"
model = "gemini-2.5-flash"
priority = 10
rpm_limit = 360

[[providers]]
name = "ollama-local-floor"
enabled = true
tier = "local"
base_url = "http://127.0.0.1:11434/v1"
model = "qwen2.5-coder:14b"
priority = 20
```

### Hardware Sizing for Local Models

When running local inference (Ollama, LM Studio, llama.cpp, or vLLM), choose a model quantization that uses **≤ 70% of system RAM / VRAM** so builds and tests never swap to disk:

| Available System / GPU Memory | Recommended Local Coding Model | Typical Footprint | Safe Parallel Workers |
|-------------------------------|--------------------------------|-------------------|-----------------------|
| **8 GB** | `qwen2.5-coder:3b` or `llama3.2:3b` | ~2.5 GB | 1 worker |
| **16 GB** | `qwen2.5-coder:7b` | ~5.0 GB | 1–2 workers |
| **24–32 GB** | `qwen2.5-coder:14b` | ~9.5 GB | 2–3 workers |
| **48–64+ GB** | `qwen2.5-coder:32b` | ~20 GB | 4–6 workers |

See [Hardware & RAM Profiles](operations/INFERENCE_PROFILES.md) for backend-specific flags.

---

## 3. Common Daily Workflows

### 3.1 Protect Any Git Repository

Install the native Rust git hooks and initialize `.chump/state.db`:

```bash
cd /path/to/your-repo
chump init --yes
chump hook install
chump hook status
```

Even if you only run interactive agents in separate terminal tabs (Claude Code, Cursor, Codex, Aider), `chump hook` immediately prevents two sessions from committing to the same leased file or pushing accidental secrets.

### 3.2 Reserve, Claim, Edit, and Ship a Task

```bash
# 1. Reserve a collision-free task ID in .chump/state.db
chump gap reserve --domain INFRA --title "Add request timeout middleware" --priority P1 --effort s

# 2. Atomically acquire a file lease and create an isolated git worktree
chump claim INFRA-001 --role target --paths "src/middleware/**"

# 3. Work inside the isolated worktree (with any IDE, CLI agent, or chump --once)
cd /tmp/chump-infra-001
# ... make edits and add unit tests ...

# 4. Run local preflight (formatting, clippy, compile, and scoped tests)
chump preflight

# 5. Push and open a verified pull request
chump ship --gap INFRA-001 --mode manual
```

### 3.3 Run Supervised Background Workers (`chumpd`)

Register and launch the cross-platform `chumpd` supervisor (`LaunchAgents` on macOS, `systemd --user` on Linux, `ChumpDaemon` Scheduled Task on Windows):

```bash
chump service install
chump up
chump service status
```

Adjust concurrency or pause autonomous execution instantly at any time:

```bash
chump fleet level 3      # Supervised worker pool
chump fleet level 0      # Immediate fail-closed stop (kill-switch)
chump fleet status       # Inspect active claims, worker health, and recent merges
```

### 3.4 Onboard and Improve an External Repository

Scan any `owner/repo` checkout, file grounded tasks with `file:line` citations, implement a fix in an isolated worktree, and run base-vs-head test verification before merging:

```bash
chump onboard owner/repo --apply
chump improve owner/repo --apply
chump external verify-merge --pr 42 --repo owner/repo --gap INFRA-001
```

### 3.5 One-Shot Local Prompt (`chump --once`)

Ask the built-in governed agent to answer a question or run a scoped task directly from your terminal:

```bash
chump --once "Summarize open P1 gaps and check which paths are currently leased" --why
```

---

## 4. Troubleshooting

### `LeaseCollisionGuard` blocks a `git commit`

Another active session holds a lease on one or more staged files. Inspect active locks:

```bash
ls -la .chump-locks/*.json
```

Either coordinate with the owning session, wait for its TTL to expire, or—if the owning terminal crashed—let `chumpd`'s automatic dead-PID lease reaper clean it up (or release your own session lease with `chump --release`).

### `connection refused` on local port `11434` / `8000`

Your local model server (`ollama serve`, LM Studio, or vLLM) is not running. Start the model server first and verify `curl -s http://127.0.0.1:11434/v1/models` returns JSON before re-running `chump`. See [Inference Stability](operations/INFERENCE_STABILITY.md).

### `chump config validate` reports an unrecognized key or invalid slot

Run `chump config show` to inspect effective settings, or paste your configuration into the browser-based [Config Doctor](https://repairman29.github.io/chump/tools/config-doctor/) to auto-remediate syntax and schema issues.

### High CPU or disk usage during parallel Rust builds

Chump's `chump-pal` host prober automatically caps `CARGO_BUILD_JOBS` on low-RAM machines during `chump preflight`. If your `target/` directory grows large over weeks of heavy development, run `cargo clean` or follow [Storage & Worktree Hygiene](operations/STORAGE_AND_ARCHIVE.md).

---

## 5. Next Steps

- **Air-gapped local setup:** [Offline Local Models](QUICKSTART_OFFLINE.md)
- **Web cockpit tour:** [Web Cockpit (`/v2/`)](PWA_USER_GUIDE.md)
- **Multi-agent lease mechanics:** [File Leases & Worktrees](process/AGENT_COORDINATION.md)
- **40-slot cascade & OAuth:** [Provider Cascade & OAuth](architecture/PROVIDER_CASCADE.md)
