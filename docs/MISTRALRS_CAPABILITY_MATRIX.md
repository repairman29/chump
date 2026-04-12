# mistral.rs capability matrix (upstream vs Chump)

**Pinned crate:** `mistralrs` **0.8.1** ([Cargo.toml](../Cargo.toml)). This doc maps upstream APIs to Chump wiring, operator env, and strategy links. For day-to-day setup, use [INFERENCE_PROFILES.md](INFERENCE_PROFILES.md) §2b.

**Strategy context:** [HIGH_ASSURANCE_AGENT_PHASES.md](HIGH_ASSURANCE_AGENT_PHASES.md) Phase 1 — **WP-1.1**–**WP-1.3** (runbook, stack UX, MCP RFC) plus **WP-1.4** (this matrix + env + CI smoke), **WP-1.6** (optional SSE **`text_delta`** for in-process mistral on web/RPC + Discord approval path), and Tier **A** [METRICS.md](METRICS.md) §1c (**`llm_last_completion`**); [TOP_TIER_VISION.md](TOP_TIER_VISION.md) §1; [rfcs/RFC-inference-backends.md](rfcs/RFC-inference-backends.md); [rfcs/RFC-wp13-mistralrs-mcp-tools.md](rfcs/RFC-wp13-mistralrs-mcp-tools.md) (tool registry **Option A** — no mistral-native MCP discovery in the hot path).

| Phase 1 WP | Scope |
|------------|--------|
| **WP-1.1** | Operator runbook (when to use in-process vs HTTP, Metal/CPU, `HF_TOKEN`, failures) |
| **WP-1.2** | Health / PWA / stack-status when mistral is primary |
| **WP-1.3** | MCP client for tools — **rejected** as default; Chump registry only |
| **WP-1.4** | Capability matrix; extra `TextModelBuilder` env; compile CI for `mistralrs-infer` |
| **WP-1.5** | **Multimodal in-tree** — [RFC-mistralrs-multimodal-in-tree.md](rfcs/RFC-mistralrs-multimodal-in-tree.md) (**Proposed**); implementation after RFC **Accepted** |
| **WP-1.6** | **Token streaming (web/RPC)** — [RFC-mistralrs-token-streaming.md](rfcs/RFC-mistralrs-token-streaming.md) (**Accepted**); optional **`CHUMP_MISTRALRS_STREAM_TEXT_DELTAS`** + [`StreamingProvider`](../src/streaming_provider.rs) |

---

## Integration surface

| Area | Upstream (mistralrs 0.8.1) | Chump today | Env / build |
|------|----------------------------|-------------|-------------|
| Text chat + tools | `TextModelBuilder` → `Model::send_chat_request` | [`src/mistralrs_provider.rs`](../src/mistralrs_provider.rs) `Provider::complete` | `--features mistralrs-infer` or `mistralrs-metal`; `CHUMP_INFERENCE_BACKEND=mistralrs`, `CHUMP_MISTRALRS_MODEL` |
| Auto ISQ bit width | `IsqBits::{Two, Three, Four, Five, Six, Eight}` via `with_auto_isq` | Wired: `CHUMP_MISTRALRS_ISQ_BITS` → `2`–`8` (invalid → `8`) | `.env` |
| Specific ISQ type (e.g. MXFP4) | `with_isq(IsqType::…)` | **Not wired** — use **`with_auto_isq`** bit targets only; advanced types need explicit env design + tests or GGUF/UQFF builders | Future WP or sidecar |
| HF revision | `with_hf_revision` | Wired: `CHUMP_MISTRALRS_HF_REVISION` (non-empty) | `.env` |
| Prefix cache | Default 16 seqs in builder; `with_prefix_cache_n(Option<usize>)`, `None` disables | Wired: `CHUMP_MISTRALRS_PREFIX_CACHE_N` — integer, or `off` / `none` / `disable` | `.env` |
| MoQE ISQ org | `with_mixture_qexperts_isq` | Wired: `CHUMP_MISTRALRS_MOQE=1` | `.env` |
| PagedAttention | `with_paged_attn(PagedAttentionConfig)` from `PagedAttentionMetaBuilder` (ignored on unsupported platforms) | Wired: `CHUMP_MISTRALRS_PAGED_ATTN=1` uses default meta builder | `.env` |
| Throughput logging | `with_throughput_logging` | Wired: `CHUMP_MISTRALRS_THROUGHPUT_LOGGING=1` | `.env` |
| Force CPU / runner logging | `with_force_cpu`, `with_logging` | Existing: `CHUMP_MISTRALRS_FORCE_CPU`, `CHUMP_MISTRALRS_LOGGING` | `.env` |
| Provider cascade vs local | N/A (Chump routing) | Mistral env wins over HTTP cascade when feature + env set; see [PROVIDER_CASCADE.md](PROVIDER_CASCADE.md) | — |
| Which backend answered (last + totals) | N/A | [`llm_backend_metrics.rs`](../src/llm_backend_metrics.rs); **`GET /api/stack-status`** / **`GET /health`** — [METRICS.md](METRICS.md) §1c | — |
| **Token streaming** | `Model::stream_chat_request` + `futures::Stream` chunks | **Wired (opt-in)** when **`CHUMP_MISTRALRS_STREAM_TEXT_DELTAS=1`** (or `true`): [`StreamingProvider`](../src/streaming_provider.rs) + [`complete_with_text_deltas`](../src/mistralrs_provider.rs). **Surfaces `text_delta`:** PWA / **`POST /api/chat`** SSE and JSONL RPC only. **Discord:** tool-approval path uses the same wrapper (mistral stream runs in-process) but the bot only **renders** **`TurnComplete.full_text`** (no incremental channel updates). **Not** on HTTP cascade / `LocalOpenAIProvider` or Discord **standard** turns ([`build_agent`](../src/discord.rs) → axonerai **`Agent`**, no **`StreamingProvider`**). | **`CHUMP_MISTRALRS_STREAM_TEXT_DELTAS`**; [RFC-mistralrs-token-streaming.md](rfcs/RFC-mistralrs-token-streaming.md) (**WP-1.6**). For HTTP streaming without this flag, use **`mistralrs serve`** + `OPENAI_API_BASE`. |
| Multimodal (vision / audio) | `MultimodalModelBuilder`, `MultimodalMessages`, examples under `examples/getting_started/multimodal/` | **Not wired** (text-only path). | [RFC-mistralrs-multimodal-in-tree.md](rfcs/RFC-mistralrs-multimodal-in-tree.md) (**WP-1.5** — **Proposed**); implement after **Accepted**. |
| GGUF / UQFF loaders | `GgufModelBuilder`, `UqffTextModelBuilder` | **Not wired** (HF id via `TextModelBuilder::new` only). | Optional future env to select builder type. |
| Embeddings | `EmbeddingModelBuilder` | **Not integrated**; Chump uses **fastembed** under `inprocess-embed`. | [Cargo.toml](../Cargo.toml) |
| MCP client on model | `with_mcp_client` | **Intentionally unused** (registry Option A). | [RFC-wp13](rfcs/RFC-wp13-mistralrs-mcp-tools.md) |
| Structured output / grammar | `generate_structured`, constraints in `RequestBuilder` | **Not wired** in provider (standard chat completion only). | Future if agent loop needs schema-first tool args beyond current JSON parsing. |
| Chat sliding window + hybrid memory | N/A (Chump) | HTTP + in-process providers use [`apply_sliding_window_to_messages_async`](../src/local_openai.rs); optional **`CHUMP_CONTEXT_HYBRID_MEMORY`** → [`recall_for_context`](../src/memory_tool.rs). | [CONTEXT_ASSEMBLY_AUDIT.md](CONTEXT_ASSEMBLY_AUDIT.md) |
| X-LoRA / AnyMoE / speculative | Dedicated builders in upstream | **Not wired** | [TOP_TIER_VISION.md](TOP_TIER_VISION.md) mentions X-LoRA as vision-only. |

---

## PagedAttention and KV cache

Upstream applies PagedAttention inside the engine when configured; default `TextModelBuilder::new` sets `prefix_cache_n: Some(16)` unless overridden. Chump does not expose per-layer topology or custom `MemoryGpuConfig` via env; operators who need that should use upstream **`mistralrs serve`** or extend [`build_mistral_model`](../src/mistralrs_provider.rs) behind new env vars with tests.

---

## CI and bitrot

- **Script:** [`scripts/check-mistralrs-infer-build.sh`](../scripts/check-mistralrs-infer-build.sh) — `cargo check` + small unit tests (no model download).
- **Workflow:** `.github/workflows/mistralrs-infer.yml` — on PRs that touch mistral-related paths, weekly cron, and `workflow_dispatch`.
- **Local hardware benchmarks:** [MISTRALRS_BENCHMARKS.md](MISTRALRS_BENCHMARKS.md) — `mistralrs tune` wrapper + CSV bench for in-process Chump.

---

## Operator sync (code ↔ env)

When adding or renaming **`CHUMP_MISTRALRS_*`** knobs in [`src/mistralrs_provider.rs`](../src/mistralrs_provider.rs), update the **Integration surface** table above and [INFERENCE_PROFILES.md](INFERENCE_PROFILES.md) §2b if the knob is user-facing. **`CHUMP_INFERENCE_BACKEND=mistralrs`** + **`CHUMP_MISTRALRS_MODEL`** remain the minimum to select in-process text chat.

## Related docs

| Doc | Topic |
|-----|--------|
| [MISTRALRS_AGENT_POWER_PATH.md](MISTRALRS_AGENT_POWER_PATH.md) | Metrics, A/B modes (HTTP vs in-process), tune→env, streaming vs Discord gap |
| [INFERENCE_PROFILES.md](INFERENCE_PROFILES.md) §2b | Metal, `HF_TOKEN`, failure modes, cascade precedence |
| [OPERATIONS.md](OPERATIONS.md) | Runtime ops |
| [WEB_API_REFERENCE.md](WEB_API_REFERENCE.md) | Stack status when mistral is primary |
| [METRICS.md](METRICS.md) §1c | **`llm_last_completion`** / **`llm_completion_totals`** (Tier **A**) |
| [rfcs/RFC-mistralrs-token-streaming.md](rfcs/RFC-mistralrs-token-streaming.md) | **WP-1.6** SSE **`text_delta`** + Discord approval-path parity |

---

## Next tier (backlog — not WP-1.4)

Aligned with the **world-class mistral.rs** essay/plan tiers:

| Tier | Item | Notes |
|------|------|--------|
| **B** | Multimodal in-tree | **Step 1 done:** [RFC-mistralrs-multimodal-in-tree.md](rfcs/RFC-mistralrs-multimodal-in-tree.md) (**Proposed**, **WP-1.5 Partial**). **Next:** Accept RFC → implement Option A phases (AxonerAI `Message` → `MultimodalModelBuilder` → Discord/PWA → battle QA). |
| **B** | Token streaming | **Shipped (narrow):** in-process mistral + web/RPC + Discord **tool-approval** path + **`CHUMP_MISTRALRS_STREAM_TEXT_DELTAS`** — [RFC-mistralrs-token-streaming.md](rfcs/RFC-mistralrs-token-streaming.md). **Still open:** HTTP provider SSE parity, AxonerAI `Provider` streaming trait, Discord **standard** turns (no **`StreamingProvider`**), incremental **`text_delta`** UI on Discord. |
| **A** | Per-turn **which backend** metrics | **Shipped:** in-process counters + last completion — [`llm_backend_metrics.rs`](../src/llm_backend_metrics.rs); **`GET /api/stack-status`** → **`llm_last_completion`**, **`llm_completion_totals`**; **`GET /health`** (health port) same keys. Kinds: **`mistralrs`**, **`cascade`** (slot name), **`openai_http`** (host:port), **`openai_api`** (model id). Cascade warm probes and inner HTTP calls do not double-count. |
| **C** | MCP bridge / governance / swarms | [HIGH_ASSURANCE_AGENT_PHASES.md](HIGH_ASSURANCE_AGENT_PHASES.md) Phase 7+; not mistral crate depth |
| **Tooling** | Upstream **`mistralrs tune`** (or equivalent) | **Runbook:** [INFERENCE_PROFILES.md](INFERENCE_PROFILES.md) §**2b.8**; upstream [CLI.md](https://github.com/EricLBuehler/mistral.rs/blob/master/docs/CLI.md). Chump does not shell out to `tune` — map bit-width to **`CHUMP_MISTRALRS_ISQ_BITS`** or run **`mistralrs serve`** / **`from-config`** + **`OPENAI_API_BASE`**. |
