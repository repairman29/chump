# RFC: Inference backends for Chump (HTTP sidecars vs Rust-native)

**Status:** Draft (Option **C** is partially implemented — see below)  
**Date:** 2026-04-11  
**Owners:** TBD

## Problem

Chump’s cognitive loop talks to models through an **OpenAI-compatible HTTP** surface (`OPENAI_API_BASE`, provider cascade, local Ollama / vLLM-MLX, etc.). External strategy docs sometimes propose **in-process Rust inference** (e.g. mistral.rs / Candle ecosystem) to reduce Python-process OOMs and simplify ops.

## Options

### A. Status quo + hardening

- Keep HTTP providers; improve **watchdogs**, **fallback slots**, **documentation** for MLX OOM vs Ollama ([INFERENCE_STABILITY.md](../INFERENCE_STABILITY.md), [PROVIDER_CASCADE.md](../PROVIDER_CASCADE.md)).
- **Pros:** No agent-loop rewrite.  
- **Cons:** Still depends on external server process health.

### B. Sidecar native inference

- Run a **separate** Rust (or other) inference binary exposing `/v1/*` on localhost; Chump unchanged at `Provider` boundary.
- **Pros:** Process isolation; incremental migration.  
- **Cons:** Packaging + GPU binding still non-trivial.

### C. In-process `Provider` implementation

- Link a Rust inference library inside `chump` and implement `Provider` for it.
- **Pros:** Single process; tight latency.  
- **Cons:** Large dependency, GPU lifecycle inside agent, build matrix explosion.

## Decision criteria

- Battle QA + autonomy tests green.
- Clear memory **budget** story per hardware tier.
- Defense pilot: **reproducible** build and **no surprise** outbound calls when air-gapped.

## Outcome

- **2026-04:** Optional in-process path landed as Cargo feature **`mistralrs-infer`** (and **`mistralrs-metal`** on Apple Silicon when Xcode metal toolchain is installed). Env: **`CHUMP_INFERENCE_BACKEND=mistralrs`**, **`CHUMP_MISTRALRS_MODEL`**. Documented in [INFERENCE_PROFILES.md](../INFERENCE_PROFILES.md) §2b. Default ops profile remains HTTP (**vLLM-MLX** / Ollama).
- **2026-04 (agent power path):** Operator metrics, fixed A/B prompts, `mistralrs-inference-ab-smoke.sh`, `env-mistralrs-power.sh`, and PWA streaming default for `run-web-mistralrs-infer.sh` — [MISTRALRS_AGENT_POWER_PATH.md](../MISTRALRS_AGENT_POWER_PATH.md); sprint backlog in [ROADMAP_SPRINTS.md](../ROADMAP_SPRINTS.md) **S2–S3**.
- HTTP sidecars (**A/B**) remain fully supported; no requirement to use mistral.rs in-process.

## Related — tools and MCP (WP-1.3)

Chump does **not** use mistral.rs’s MCP client for tool discovery. Tools remain **`tool_inventory.rs`** only; see [RFC-wp13-mistralrs-mcp-tools.md](RFC-wp13-mistralrs-mcp-tools.md).

## Related — multimodal in-process (WP-1.5)

Text-only in-process path today; vision/media requires message-model and pipeline work — see [RFC-mistralrs-multimodal-in-tree.md](RFC-mistralrs-multimodal-in-tree.md).

## Related — token streaming (WP-1.6)

Optional SSE **`text_delta`** for **web + JSONL RPC** when in-process mistral is primary — env **`CHUMP_MISTRALRS_STREAM_TEXT_DELTAS`**; HTTP OpenAI path unchanged. See [RFC-mistralrs-token-streaming.md](RFC-mistralrs-token-streaming.md).

## Related — upstream CLI `mistralrs tune`

Hardware-aware quantization recommendations and optional **`--emit-config`** TOML are **upstream CLI only**; Chump maps coarse bit targets via **`CHUMP_MISTRALRS_ISQ_BITS`** or uses **`mistralrs serve`** / **`from-config`** over HTTP. See [INFERENCE_PROFILES.md](../INFERENCE_PROFILES.md) §2b.8 and [MISTRALRS_CAPABILITY_MATRIX.md](../MISTRALRS_CAPABILITY_MATRIX.md) Next tier **Tooling**.
