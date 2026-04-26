---
doc_tag: log
owner_gap:
last_audited: 2026-04-25
---

# Universal Power Roadmap

Long-horizon capability backlog for Chump — items that represent the broader north-star architecture vision. These are not the operational near-term backlog (that lives in [ROADMAP.md](ROADMAP.md)) but the architectural bets worth tracking.

## In-process inference

Replace the HTTP inference hop with `mistral.rs` running in-process. Eliminates latency from `reqwest` → `axum` round-trips for each completion.

- `CHUMP_INFERENCE_BACKEND=mistralrs` + Metal build already ships this path
- **Remaining:** ISQ quantization tuning, upstream `mistralrs tune` for RAM hints, Pixel (llama-server HTTP only — no in-process path on Android)
- See [INFERENCE_PROFILES.md](INFERENCE_PROFILES.md) §2b

## eBPF observability

Zero-overhead kernel-level tracing of tool execution — syscalls, file descriptors, network connections — without modifying Chump code. Would give an audit trail that can't be tampered with by the agent itself.

- Requires Linux kernel ≥ 5.8 (not macOS)
- Useful for the hardened/defense posture

## Managed browser (Firecrawl integration)

Replace the current `read_url` scrape tool with a fully rendered browser — JavaScript execution, cookie sessions, form fills. Firecrawl provides this as an API.

- Currently `read_url` fetches raw HTML only
- Gated behind `CHUMP_AIR_GAP_MODE=0` (excluded in air-gap posture)

## Stateless task decomposition

Break long agent turns into checkpointed sub-tasks that can be restarted from a snapshot if the process crashes mid-way. Currently, a crash during a multi-step task means all progress is lost.

- Related to `chump_tasks` + lease columns (distributed locking already ships)
- Would enable true "pause and resume" for long autonomy runs

## JIT WASM tools

Compile user-defined tool logic to WASM at runtime, sandboxing it away from host shell. Currently WASM tools are pre-compiled modules.

- See [WASM_TOOLS.md](WASM_TOOLS.md) for the existing bounded WASM tool architecture
- JIT would enable user-uploaded tool logic without redeploying Chump

## MCP ecosystem bridge

A generic Model Context Protocol bridge so any MCP-compliant tool server can be registered in Chump without a custom integration.

- RFC filed: [rfcs/RFC-wp23-mcp-sandboxscan-class.md](rfcs/RFC-wp23-mcp-sandboxscan-class.md)
- Currently tools are native Rust implementations

## Fleet mesh inference (Pi nodes)

Split inference across multiple small devices — 1B models on edge nodes, 7B on mid-tier, 14B on the Mac. Requires the inference mesh routing layer.

- See [INFERENCE_MESH.md](INFERENCE_MESH.md) for current topology
- Transport layer: Tailscale + WebSocket push (spike design in [FLEET_ROLES.md](FLEET_ROLES.md))

## See Also

- [Roadmap](ROADMAP.md) — operational near-term backlog
- [Chump to Champ](CHUMP_TO_CHAMP.md) — cognitive architecture frontier
- [Inference Mesh](INFERENCE_MESH.md)
