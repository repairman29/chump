# Chump

**Run 2 to 24 coding agents on one repository—without merge stomps or runaway API bills.**

Chump is a local-first Rust multi-agent coordinator, pre-commit file-lease firewall, and 40-slot model failover router for **macOS, Linux, and Windows**. Bring the coding agents you already use (**Claude Code**, **Codex CLI**, **OpenCode**, **Aider**, **goose**, or manual git commits) or run **100% offline on local Ollama / vLLM**. Runs on hardware you own—zero seat fees, zero token markup, zero cloud middleman.

**Product Site & Interactive Tools:** [repairman29.github.io/chump](https://repairman29.github.io/chump/) · **Documentation:** [repairman29.github.io/chump/docs](https://repairman29.github.io/chump/docs/) · **Offline Ollama Guide:** [docs/QUICKSTART_OFFLINE.md](docs/QUICKSTART_OFFLINE.md) · **License:** AGPL-3.0 (binaries) + Apache-2.0 (13 library crates; see [NOTICE](NOTICE))

---

## Why Chump Exists

Running one coding agent inside one terminal is solved. Running five in parallel against the same `main` branch breaks down in four predictable ways:

| Failure Mode | 5 Raw Agent Tabs (Without Chump) | Parallel Fleet Supervised by Chump |
|---|---|---|
| **Shared file edits** | Silent overwrites & painful git rebase conflicts | **Sub-2ms Rust `pre-commit` path & symbol lease firewall** |
| **Upstream HTTP 429 / quota hit** | Mid-refactor crash or stalled terminal session | **40-slot failover across OAuth, fast APIs & `$0` local Ollama** |
| **Agent claims “Done!” early** | Unpushed branch, failing tests, or hallucinated merge | **Proof-of-merge check verifies commit on `origin/main` before closing** |
| **CI & git hook edits** | Agent weakens `.github/workflows/` to pass checks | **Compile-time gate guard holds `--auto-merge` for human review** |

Chump ships two independent, composable layers in one binary:

- **1. The Coordinator (works with any coding agent):** SQLite WAL task queue (`.chump/state.db`), path and symbol-region file leases (`.chump-locks/`), isolated git worktrees, an `ambient.jsonl` event stream, native Rust `pre-commit` / `pre-push` guards (`chump hook`), and a gate-guarded PR shipper (`chump ship`).
- **2. The Built-in Local Agent (optional):** Connects directly to Ollama, LM Studio, llama.cpp, vLLM, or your configured provider cascade, keeps persistent SQLite FTS5 + graph memory, exposes 30+ approval-gated tools, and speaks CLI, web cockpit (`/v2/`), Discord, or [Agent Client Protocol (`chump --acp`)](docs/architecture/ACP.md) for Zed and JetBrains.

---

## 60-Second Install & Quickstart

### 1. Install the Binary

```bash
# macOS (Homebrew pre-built bottle, ~25s)
brew tap repairman29/chump && brew install chump

# Linux (POSIX shell binary installer — x86_64 & aarch64)
curl --proto '=https' --tlsv1.2 -LsSf https://github.com/repairman29/chump/releases/latest/download/chump-installer.sh | sh

# Windows or Cargo from source (macOS / Linux / Windows)
cargo install --git https://github.com/repairman29/chump chump --locked
```

### 2. Adopt Incrementally in Any Git Repository

```bash
# Step 1 (5s): Add <2ms Rust pre-commit lease-collision & secret-leak guards
chump hook install
chump hook status

# Step 2 (20s): Scaffold & validate ~/.chump/config.toml (%USERPROFILE%\.chump\config.toml on Windows)
chump config init
chump config validate

# Step 3 (35s): Register the native background supervisor + open the local cockpit
#   - macOS:   ~/Library/LaunchAgents/com.chump.chumpd.plist (launchctl)
#   - Linux:   ~/.config/systemd/user/chumpd.service (systemd --user)
#   - Windows: Scheduled Task "ChumpDaemon" (schtasks)
chump service install
chump up
chump --web --port 3847
```

---

## Four Mix-and-Match Model & Harness Lanes

Configure `~/.chump/config.toml` once to combine subscriptions, API keys, external CLIs, and local GPUs:

1. **Connected Subscriptions / OAuth (`[auth] mode = "auto"`):** Syncs `CLAUDE_CODE_OAUTH_TOKEN`, macOS Keychain `"Claude Code-credentials"`, or `~/.claude/.credentials.json` (`%USERPROFILE%\.claude\.credentials.json` on Windows) automatically via `chumpd`.
2. **Up to 40 Cascading API-Key Slots (`[[providers]]`):** Route across Gemini, Mistral Codestral, Groq, Cerebras, Together, DeepSeek, OpenRouter, Anthropic, or OpenAI with RPM headroom throttling, circuit breakers, and adaptive reliability scoring.
3. **Bring Your Own Coding Harness (`[fleet] harness`):** Dispatch parallel workers through `claude`, `opencode`, `codex`, `aider`, `goose`, or manual commits—all governed by the same file leases and `chump ship` firewall.
4. **`$0` Air-Gap Local Endpoints (`tier = "local"`):** Point `base_url` at local `Ollama` (`http://127.0.0.1:11434/v1`), `LM Studio` (`:1234/v1`), `llama.cpp` (`:8080/v1`), or `vLLM` (`:8000/v1`) with zero API keys or internet connection required.

```toml
# Example ~/.chump/config.toml (validate anytime with: chump config validate)
[auth]
mode = "auto"

[fleet]
mode = "grind"
desired_workers = 4
harness = "claude"
disk_floor_gb = 5.0
auto_merge = true

[web]
bind_addr = "127.0.0.1"
port = 3847

[[providers]]
name = "gemini-flash"
base_url = "https://generativelanguage.googleapis.com/v1beta/openai"
api_key_env = "GEMINI_API_KEY"
model = "gemini-2.5-flash"
rpm_limit = 360
priority = 10
tier = "cloud"

[[providers]]
name = "ollama-local-floor"
base_url = "http://127.0.0.1:11434/v1"
model = "qwen2.5-coder:14b"
priority = 20
tier = "local"
```

---

## Core Coordinator Primitives

| Primitive | What It Does |
|---|---|
| **`chump gap` (`.chump/state.db`)** | SQLite WAL task queue (`reserve`, `list`, `preflight`, `link-pr`, `ship`) with duplicate-task detection and proof-of-merge verification. |
| **`chump claim` (`.chump-locks/*.json`)** | Atomic path (`crates/foo/*`) and symbol (`src/auth.rs::verify`) leases with heartbeat TTLs and isolated git worktree creation. |
| **`chump hook` (`crates/chump-git-hooks`)** | Compiled Rust `pre-commit` and `pre-push` firewall blocking cross-session lease collisions, credential leaks, and formatting drift. |
| **`chump preflight` (`crates/chump-preflight`)** | Host-RAM-aware `CARGO_BUILD_JOBS` guard (`chump-pal`) + `cargo fmt`, `clippy -D warnings`, and scoped test suites before pushing. |
| **`chump ship` (`crates/chump-ship`)** | Single-instance PR shipper that rebases clean stacks, opens PRs, refuses `--auto-merge` on `.github/workflows/*` or hook edits, and verifies merge landing. |
| **`ambient.jsonl`** | Append-only RFC3339 coordination log of claims, commits, lease blocks, rate-limit signals, and ship receipts. |

---

## Five-Minute CLI Walkthrough

1. **Interactive first-run setup** (checks local Ollama or API credentials and initializes `.chump/state.db`):
   ```bash
   chump init
   ```
2. **One-shot a scoped task** (reads the repo, generates a patch, runs checks, and opens a PR):
   ```bash
   chump gen "add a /health endpoint to my axum server"
   # Or classify + dispatch CREATE / IMPROVE / INGEST automatically:
   chump trek "add a /health endpoint to my axum server" --yes
   ```
3. **Bootstrap a brand-new project from scratch**:
   ```bash
   chump bootstrap "A CLI tool that syncs files across machines" --dir /tmp/myproject --skip-arch-decision
   ```
4. **Drive or inspect a parallel worker pool**:
   ```bash
   chump fleet level 3             # Supervised 2-worker cap (0 = hard STOP kill-switch)
   chump fleet status              # Live claims, recent merges, and health grades
   chump orchestrate               # Conversational multi-agent command loop
   ```

---

## Build from Source

```bash
git clone https://github.com/repairman29/chump.git && cd chump
cp .env.minimal .env
cargo build --bin chump

# Launch the web cockpit (via helper wrapper or direct binary)
./run.sh web
# Or one-shot local prompt via helper wrapper:
./run.sh local -- --chump "Summarize open tasks"

# Verify clean-path setup without requiring a live model:
./scripts/ci/verify-external-golden-path.sh
```

> **Linux system packages (optional Tauri desktop build):** Run `bash scripts/setup/provision-chumpd-host.sh --install-deps` on Ubuntu 22.04/24.04 to install GTK/WebKit headers, Rust, and `gh`.

---

## Documentation & Architecture

Browse the full documentation hub at **[repairman29.github.io/chump/docs](https://repairman29.github.io/chump/docs/)**:

| Document | Purpose |
|----------|---------|
| [`AGENTS.md`](AGENTS.md) | Tool-agnostic contributor & coding-agent guide (build, test, lint, conventions) |
| [`CLAUDE.md`](CLAUDE.md) | Session lease, `ambient.jsonl`, and ship-pipeline rules for Chump fleet workers |
| [`docs/USER_GUIDE.md`](docs/USER_GUIDE.md) | Everyday workflows, model profiles, and troubleshooting |
| [`docs/QUICKSTART_OFFLINE.md`](docs/QUICKSTART_OFFLINE.md) | 5-step air-gapped local setup on Ollama |
| [`docs/PWA_USER_GUIDE.md`](docs/PWA_USER_GUIDE.md) | Local web cockpit (`/v2/`) operator guide |
| [`docs/process/EXTERNAL_GOLDEN_PATH.md`](docs/process/EXTERNAL_GOLDEN_PATH.md) | Clean-machine verification walkthrough |
| [`docs/architecture/ARCHITECTURE.md`](docs/architecture/ARCHITECTURE.md) | System and crate-level architecture reference |
| [`docs/process/AGENT_COORDINATION.md`](docs/process/AGENT_COORDINATION.md) | File leases, worktrees, failure recovery, and pre-commit firewall spec |
| [`docs/architecture/ACP.md`](docs/architecture/ACP.md) | Agent Client Protocol (`chump --acp`) integration for Zed & JetBrains |
| [`docs/operations/OPERATIONS.md`](docs/operations/OPERATIONS.md) | Daemon supervision, environment variables, and health checks |
| [`docs/ROADMAP.md`](docs/ROADMAP.md) & [`docs/strategy/NORTH_STAR.md`](docs/strategy/NORTH_STAR.md) | Active roadmap and founding product thesis |
| [`CONTRIBUTING.md`](CONTRIBUTING.md) & [`SECURITY.md`](SECURITY.md) | Contribution checklist and vulnerability reporting |

### Empirical Research Note

Alongside its production coordinator, Chump includes an opt-in evaluation harness (`experimental-cognition` Cargo feature, off by default in v1.0) for studying tier-dependent instruction injection and memory retrieval across local and frontier models. See [`docs/process/RESEARCH_INTEGRITY.md`](docs/process/RESEARCH_INTEGRITY.md) and [`docs/research/RESEARCH_COMMUNITY.md`](docs/research/RESEARCH_COMMUNITY.md) for methodology and reproducibility rules.
