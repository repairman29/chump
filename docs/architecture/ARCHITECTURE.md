---
doc_tag: canonical
owner_gap: PRODUCT-375
last_audited: 2026-11-27
---

# System Architecture

## 1. Universal v1.0 Multi-OS Control Plane

Chump v1.0 runs natively on **macOS, Linux, and Windows** as a pure-Rust multi-agent coordinator and optional governed coding agent—requiring zero `tmux`, bash daemon wrappers, or Unix-only sockets:

| Subsystem | Workspace Crates & Modules | Architectural Role |
|-----------|----------------------------|--------------------|
| **CLI & Dispatch Switchboard (`chump`)** | `src/main.rs` + `src/cli_dispatch/*` | Single binary entrypoint for task coordination (`gap`, `claim`, `preflight`, `ship`), configuration (`config`), git firewall (`hook`), service supervision (`service`, `up`, `fleet`), Web Cockpit (`--web`), and ACP (`--acp`). |
| **Background Supervisor (`chumpd`)** | `crates/chumpd` (`main.rs`, `worker_loop.rs`, `oauth_sync.rs`, `lease_reaper.rs`) | Cross-platform worker-pool supervisor with loopback TCP IPC (`127.0.0.1:<port>` in `.chump/chumpd.addr`), 5-minute atomic `0600` OAuth credential refresh, dead-PID/expired `.chump-locks/*.json` reaper, and RFC3339 `ambient.jsonl` telemetry. |
| **Platform Abstraction Layer** | `crates/chump-pal` (`host`, `process`, `signal`, `paths`, `shell`, `ipc`, `win32`) | Host RAM/CPU/disk probing, Unix PGID and Win32 Job Object process-tree cleanup, cross-OS home/config path resolution (`CHUMP_HOME` / `HOME` / `USERPROFILE`), `sh -c` vs `cmd /C` execution, and single-instance lockfiles. |
| **Config & 4-Lane Model Router** | `crates/chump-config`, `src/auth.rs`, `src/provider_cascade.rs`, `src/local_openai.rs` | Schema-validated `~/.chump/config.toml` + env overrides uniting (1) Subscription OAuth, (2) 40-slot API-key cascade with RPM headroom, circuit breakers, and `BanditRouter`, (3) BYO CLI harnesses (`claude`, `opencode`, `codex`, `aider`, `goose`), and (4) `$0` local endpoints (`Ollama`, `LM Studio`, `llama.cpp`, `vLLM`, optional in-process `mistral.rs`). |
| **Git Hook & Ship Firewall** | `crates/chump-git-hooks`, `crates/chump-ship`, `crates/chump-verify` | Sub-2ms `pre-commit` / `pre-push` guards (`LeaseCollisionGuard`, `SecretPatternGuard`, `SubmoduleSanityGuard`, `RustFmtGuard`, `ProtectedBranchGuard`) plus single-instance `chump ship` with compile-time gate-file `--auto-merge` refusal and external base-vs-head test verification. |
| **Task Ledger & Coordination Bus** | `crates/chump-gap-store`, `crates/chump-coord`, `.chump/state.db`, `.chump-locks/` | SQLite WAL task queue paired with filesystem path/symbol leases, `ambient.jsonl` event logs, and optional NATS `chump.events.*` fan-out for multi-host teams. |
| **Interactive Surfaces** | `src/web_server.rs`, `src/acp_server.rs`, `src/adapters/*` | `axum` HTTP + SSE Web Cockpit (`/v2/`), Agent Client Protocol stdio server (`--acp`), and opt-in chat adapters (`Slack`, `Telegram`, `Discord`). |

---

## 2. Governed Built-In Agent Engine (`src/agent_loop/`)

When running `chump --once`, `chump --web`, `chump --acp`, or `--harness chump-local`, turns execute through a modular seven-part pipeline in `src/agent_loop/`:

| Module | Responsibility |
|--------|----------------|
| `orchestrator.rs` | `ChumpAgent::run` entrypoint: loads session history, runs structured perception, assembles prompt context, invokes `IterationController`, and persists state. |
| `perception_layer.rs` | Classifies task intent (`code_edit`, `debug`, `research`, `question`), extracts file/version constraints, flags destructive or auth risk indicators, and scores prompt ambiguity. |
| `prompt_assembler.rs` | Orders system rules, active lease boundaries, tool schemas, and retrieved memory for high adherence across both frontier and small local models. |
| `iteration_controller.rs` | Drives the bounded `ToolUse` → `EndTurn` loop, enforces maximum turn iterations, and retries narrated non-calls cleanly. |
| `tool_runner.rs` | Executes native and structured tool batches with timeout wrappers, middle-trimmed CLI output, and post-write `ToolVerification` checks. |
| `context.rs` & `types.rs` | Strongly typed `AgentSession`, `AgentLoopContext`, streaming `AgentEvent` emitters, and context-window summarization triggers. |

### Deterministic Default vs. Experimental Cognition

By default in v1.0, `src/cognition_gate.rs` runs deterministic, zero-overhead no-op hooks so production builds remain fast and predictable. Researchers studying active-inference telemetry (`blackboard`, `precision_controller`, `neuromodulation`, `belief_state`, `counterfactual`) can opt in via `--features experimental-cognition` or `CHUMP_COGNITION_ENABLED=1`.

---

## 3. Tool Governance & Memory

- **Allow / Deny / Ask Tool Policy (`src/tool_policy.rs`):** Tools listed in `CHUMP_TOOLS_ASK` pause before execution, compute heuristic command risk without an LLM call, emit a `ToolApprovalRequest` (to Web Cockpit, ACP editor prompt, or chat adapter), and record every decision to `logs/chump.log` (`tool_approval_audit`).
- **Hybrid Persistent Memory (`src/memory_db.rs`):** SQLite `sessions/chump_memory.db` with FTS5 keyword search, confidence/TTL metadata, and optional Reciprocal Rank Fusion (RRF) semantic retrieval (`--features inprocess-embed`).
- **Machine-Readable Capability Discovery:** `docs/CAPABILITIES_REGISTRY.json` (validated against `docs/schemas/capabilities-registry.schema.json`) indexes CLI subcommands, workspace crate APIs, MCP servers, and `ambient.jsonl` event schemas for external orchestrators.

---

## Related Guides

- [Workspace Module Map](RUST_MODULE_MAP.md)
- [File Leases & Worktrees](../process/AGENT_COORDINATION.md)
- [Provider Cascade & OAuth](PROVIDER_CASCADE.md)
- [Editor Integration (ACP)](ACP.md)
