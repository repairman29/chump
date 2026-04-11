# SDA / TAP–style capability map (what Chump ships)

**Purpose:** One-page traceability for **defense / space–adjacent** conversations: each capability below maps to **code or a canonical doc**—not a claim of **production ATO**, **mission authorization**, or **weapon system integration**.

**Not legal or mission assurance advice.**

| Capability theme | What Chump actually provides | Trace (code or doc) |
|------------------|------------------------------|---------------------|
| **Local orchestration** | Single-process Rust agent; Discord / CLI / PWA / optional desktop shell | `src/main.rs`, `src/agent_loop.rs`, `src/web_server.rs` |
| **Inference** | OpenAI-compatible HTTP (vLLM-MLX, Ollama, llama-server); optional in-process mistral.rs | [INFERENCE_PROFILES.md](INFERENCE_PROFILES.md), `src/provider_cascade.rs`, `src/mistralrs_provider.rs` |
| **Tool governance** | Registration-time gates, middleware timeout/circuit/concurrency/rate limit, optional human approval | `src/tool_inventory.rs`, `src/tool_middleware.rs`, [TOOL_APPROVAL.md](TOOL_APPROVAL.md) |
| **Air-gap posture** | Disables `web_search` / `read_url` at registration when `CHUMP_AIR_GAP_MODE` | `src/env_flags.rs`, [DEFENSE_PILOT_REPRO_KIT.md](DEFENSE_PILOT_REPRO_KIT.md) §air-gap |
| **Bounded execution** | WASI tools via wasmtime (no host dirs/network by default) | [WASM_TOOLS.md](WASM_TOOLS.md), `src/wasm_runner.rs` |
| **Host-trust shell** | `run_cli` with allowlist/blocklist; not sandboxed like WASM | `src/cli_tool.rs`, [TOOL_APPROVAL.md](TOOL_APPROVAL.md) trust ladder |
| **Audit / memory** | SQLite sessions, tool health, approval audit, episode/task tools | `src/tool_health_db.rs`, `sessions/`, [OPERATIONS.md](OPERATIONS.md) |
| **Fleet / edge** | Docs and scripts for Mac + Pixel (Termux); SSH, Tailscale patterns; inference mesh env | [FLEET_ROLES.md](FLEET_ROLES.md), [ANDROID_COMPANION.md](ANDROID_COMPANION.md), [INFERENCE_MESH.md](INFERENCE_MESH.md) |
| **Compliance drafts** | Offline Markdown shells for SSP-style placeholders | [COMPLIANCE_TEMPLATES.md](COMPLIANCE_TEMPLATES.md) |

## Explicit non-claims

- **Not** a certified RMF artifact generator, eMASS integration, or accredited IL5/IL6 runtime.  
- **Not** a replacement for command-directed cybersecurity controls or operational test.  
- **Not** autonomous cyber effects; tools are **operator-configured** and **human-gated** where enabled.

## Changelog

| Date | Change |
|------|--------|
| 2026-04-09 | Initial map for WP-8.1. |
