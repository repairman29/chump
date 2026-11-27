---
doc_tag: canonical
owner_gap: PRODUCT-375
last_audited: 2026-11-27
---

# Workspace Crate & Module Map

Chump is organized as a Rust 2021 workspace pairing reusable infrastructure crates under `crates/` with the unified `chump` binary under `src/`.

---

## 1. Key Workspace Crates (`crates/`)

| Crate | License | Responsibility |
|-------|---------|----------------|
| `crates/chump-pal` | Apache-2.0 | Platform Abstraction Layer: host CPU/RAM/disk probing, Unix PGID & Win32 Job Object process trees, loopback TCP IPC, and OS paths. |
| `crates/chump-config` | Apache-2.0 | Schema-validated `~/.chump/config.toml` parser, validator, and environment override merger. |
| `crates/chump-git-hooks` | AGPL-3.0 | Native Rust `pre-commit` and `pre-push` firewall (`LeaseCollisionGuard`, `SecretPatternGuard`, `RustFmtGuard`, `ProtectedBranchGuard`). |
| `crates/chump-ship` | AGPL-3.0 | Single-instance PR shipper (`ManualShipPath`, `BotMergePath`, and compile-time gate-file `--auto-merge` refusal). |
| `crates/chumpd` | AGPL-3.0 | Cross-platform background supervisor daemon managing worker pools, 5-minute OAuth token sync, and stale lease reaping. |
| `crates/chump-gap-store` | AGPL-3.0 | SQLite WAL task registry (`.chump/state.db`), atomic ID reservation, and PR status tracking. |
| `crates/chump-preflight` | AGPL-3.0 | Scoped local CI runner (`fmt`, `clippy -D warnings`, `check`, and diff-matched test suites) with RAM-aware `CARGO_BUILD_JOBS` throttling. |
| `crates/chump-verify` | AGPL-3.0 | Commit, diff, and acceptance-criteria verification policies (`chump verify` and `external verify-merge`). |
| `crates/chump-coord` | Apache-2.0 | Lease overlap geometry, coordination messages, and NATS / local event transport primitives. |
| `crates/chump-orchestrator` | Apache-2.0 | Thompson-sampling candidate selection and multi-worker task orchestration primitives. |
| `crates/chump-cost-ledger` | Apache-2.0 | Token and USD spend accounting with configurable session and daily budget ceilings. |
| `crates/chump-mcp-lifecycle` | Apache-2.0 | Model Context Protocol (MCP) stdio server lifecycle and health management. |
| `crates/chump-tool-macro` | Apache-2.0 | Procedural macro `#[chump_tool(...)]` generating typed JSON-Schema tool registrations. |

*(See repository root `NOTICE` for the complete list of Apache-2.0 reusable library crates vs. AGPL-3.0 application binaries.)*

---

## 2. Primary Binary Modules (`src/`)

### Entrypoint, Config & Routing

| Module | Responsibility |
|--------|----------------|
| `src/main.rs` & `src/cli_dispatch/*` | CLI flag parsing and subcommand dispatch across coordinator, web, ACP, and agent modes |
| `src/config_validation.rs` | Startup environment and feature summary with secret-safe logging |
| `src/auth.rs` | Subscription OAuth and API-key credential discovery ladder |
| `src/provider_cascade.rs` | 40-slot priority & Thompson-sampling router, RPM headroom, and per-slot circuit breakers |
| `src/local_openai.rs` | OpenAI-compatible HTTP client with retry backoff and connection-vs-5xx circuit classification |
| `src/streaming_provider.rs` | Incremental SSE token and `<think>` block stream parser |

### Agent Loop, Tools & Verification

| Module | Responsibility |
|--------|----------------|
| `src/agent_loop/*` | Seven-submodule turn engine (`orchestrator`, `perception_layer`, `prompt_assembler`, `iteration_controller`, `tool_runner`, `context`, `types`) |
| `src/tool_inventory.rs` & `src/tool_routing.rs` | Compile-time tool registration and runtime tool dispatch |
| `src/tool_policy.rs` & `src/approval_resolver.rs` | Allow / Deny / Ask risk gating and interactive approval resolution |
| `src/tool_middleware.rs` | Timeouts, output trimming, and post-write `ToolVerification` checks |
| `src/execution/*` | Pluggable `local`, `docker`, and `ssh` command execution backends |
| `src/repo_tools.rs`, `src/git_tools.rs`, `src/gh_tools.rs` | Repository file read/write/patch and allowlisted Git / GitHub operations |
| `src/onboard.rs` & `src/improve.rs` | External repository onboarding (`chump onboard`) and autonomous improvement loops (`chump improve`) |

### Memory, Surfaces & Adapters

| Module | Responsibility |
|--------|----------------|
| `src/memory_db.rs` & `src/state_db.rs` | SQLite FTS5 memory, RRF hybrid recall, sessions, episodes, and DAG tasks |
| `src/web_server.rs` & `src/routes/*` | `axum` HTTP + SSE server powering `/v2/`, `/site/`, and `/api/*` |
| `src/acp.rs` & `src/acp_server.rs` | Agent Client Protocol JSON-RPC 2.0 server (`chump --acp`) |
| `src/adapters/*`, `src/slack.rs`, `src/discord.rs` | Optional messaging platform adapters (Slack Socket Mode, Telegram HTTP, Discord) |

---

## Related Guides

- [System Architecture](ARCHITECTURE.md)
- [HTTP & SSE API](../api/WEB_API_REFERENCE.md)
- [Editor Integration (ACP)](ACP.md)
