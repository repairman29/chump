---
doc_tag: canonical
owner_gap:
last_audited: 2026-04-25
---

# mistral.rs in Chump — consolidated reference

Merged from: `MISTRALRS_CAPABILITY_MATRIX.md`, `MISTRALRS_BENCHMARKS.md`, `MISTRALRS_AGENT_POWER_PATH.md`.
Source files archived after this lands (DOC-002 Phase 4).

**Pinned crate:** `mistralrs` **0.8.1** ([Cargo.toml](../Cargo.toml)).
**Day-to-day setup:** [INFERENCE_PROFILES.md](INFERENCE_PROFILES.md) §2b.

---

## Phase 1 work packages

| WP | Scope |
|----|-------|
| **WP-1.1** | Operator runbook (in-process vs HTTP, Metal/CPU, `HF_TOKEN`, failures) |
| **WP-1.2** | Health / PWA / stack-status when mistral is primary |
| **WP-1.3** | MCP client for tools — **rejected** as default; Chump registry only |
| **WP-1.4** | Capability matrix; extra `TextModelBuilder` env; compile CI for `mistralrs-infer` |
| **WP-1.5** | **Multimodal in-tree** — [RFC-mistralrs-multimodal-in-tree.md](rfcs/RFC-mistralrs-multimodal-in-tree.md) (**Proposed**) |
| **WP-1.6** | **Token streaming (web/RPC)** — [RFC-mistralrs-token-streaming.md](rfcs/RFC-mistralrs-token-streaming.md) (**Accepted**) |

---

## Integration surface (env knobs vs upstream)

| Area | Upstream (mistralrs 0.8.1) | Chump wiring | Env / build |
|------|---------------------------|-------------|-------------|
| Text chat + tools | `TextModelBuilder` → `Model::send_chat_request` | [`src/mistralrs_provider.rs`](../src/mistralrs_provider.rs) | `--features mistralrs-infer` or `mistralrs-metal`; `CHUMP_INFERENCE_BACKEND=mistralrs`, `CHUMP_MISTRALRS_MODEL` |
| Auto ISQ bit width | `IsqBits::{Two..Eight}` via `with_auto_isq` | `CHUMP_MISTRALRS_ISQ_BITS` → `2`–`8` | `.env` |
| Specific ISQ type (MXFP4, etc.) | `with_isq(IsqType::…)` | **Not wired** | Future WP |
| HF revision | `with_hf_revision` | `CHUMP_MISTRALRS_HF_REVISION` | `.env` |
| Prefix cache | Default 16 seqs; `with_prefix_cache_n(Option<usize>)` | `CHUMP_MISTRALRS_PREFIX_CACHE_N` (integer, or `off`/`none`/`disable`) | `.env` |
| PagedAttention | `with_paged_attn(PagedAttentionConfig)` | `CHUMP_MISTRALRS_PAGED_ATTN=1` | `.env` |
| Throughput logging | `with_throughput_logging` | `CHUMP_MISTRALRS_THROUGHPUT_LOGGING=1` | `.env` |
| Token streaming | `Model::stream_chat_request` | Opt-in: `CHUMP_MISTRALRS_STREAM_TEXT_DELTAS=1` — surfaces `text_delta` on PWA/RPC SSE | `.env` |
| MoQE ISQ | `with_mixture_qexperts_isq` | `CHUMP_MISTRALRS_MOQE=1` | `.env` |
| Force CPU | `with_force_cpu` | `CHUMP_MISTRALRS_FORCE_CPU=1` | `.env` |
| Multimodal | `MultimodalModelBuilder` | **Not wired** (text-only) | [RFC WP-1.5](rfcs/RFC-mistralrs-multimodal-in-tree.md) |
| GGUF / UQFF | `GgufModelBuilder`, `UqffTextModelBuilder` | **Not wired** | Optional future |
| Structured output | `RequestBuilder::set_constraint` (JsonSchema/Regex) | **Spike shipped (S3, ADR-002):** `CHUMP_MISTRALRS_OUTPUT_JSON_SCHEMA` → `Constraint::JsonSchema` on tool-free completions | `.env` |
| MCP client on model | `with_mcp_client` | **Intentionally unused** (registry Option A) | [RFC-wp13](rfcs/RFC-wp13-mistralrs-mcp-tools.md) |

**Min required env to enable in-process text chat:** `CHUMP_INFERENCE_BACKEND=mistralrs` + `CHUMP_MISTRALRS_MODEL`.

---

## Three inference modes

| Mode | Label | What you run | Chump config |
|------|-------|--------------|-------------|
| **A** | HTTP primary (prod default) | vLLM-MLX :8000, Ollama :11434, or any OpenAI-compat server | `OPENAI_API_BASE`, `OPENAI_MODEL`; unset `CHUMP_INFERENCE_BACKEND` |
| **B** | mistral.rs HTTP | Upstream `mistralrs serve` (OpenAI API on localhost) | Same as A: `OPENAI_API_BASE` → that server |
| **C** | In-process mistral.rs | Only `chump` binary | `--features mistralrs-metal` (or `mistralrs-infer`); `CHUMP_INFERENCE_BACKEND=mistralrs`; `CHUMP_MISTRALRS_MODEL`; unset `OPENAI_API_BASE` |

**Fleet (Android/Mabel):** stay on HTTP mode A — in-process mistral is not the Android path.

---

## Benchmarking

### Upstream tuning (`mistralrs tune`)
Answers "what quantization fits this GPU/RAM?" without Chump.

```bash
./scripts/eval/bench-mistralrs-tune.sh Qwen/Qwen3-4B
MISTRALRS_TUNE_PROFILE=fast ./scripts/eval/bench-mistralrs-tune.sh --json Qwen/Qwen3-4B
```

Map bit-width recommendations to `CHUMP_MISTRALRS_ISQ_BITS`.

### Chump in-process wall-clock micro-bench
Measures process-start → one completion → exit (includes ISQ/model reload):

```bash
./scripts/eval/bench-mistralrs-chump.sh --model Qwen/Qwen3-4B --isq 4,6,8 --runs 2 --warmup --summary \
  -o logs/mistralrs-chump-bench.csv
```

### A/B success metrics

| Metric | How to measure |
|--------|----------------|
| TTFT (warm) | Time from submit → first token after one warmup; use `CHUMP_MISTRALRS_THROUGHPUT_LOGGING=1` |
| Turn latency | Wall time for one full CLI `--chump` reply or PWA turn |
| Peak RSS | `top` / Activity Monitor while inference runs |
| Battle QA pass rate | `BATTLE_QA_MAX=20 ./scripts/ci/battle-qa.sh` |

**Scripted smoke:** `scripts/ci/mistralrs-inference-ab-smoke.sh` — `http` / `inproc` runs AB-2 with `time`.

---

## Streaming UX

- **PWA / `POST /api/chat` (SSE):** `CHUMP_MISTRALRS_STREAM_TEXT_DELTAS=1` — token chunks surface as `text_delta` events.
- **`scripts/dev/run-web-mistralrs-infer.sh`** exports this by default.
- **Discord standard turns:** still shows final reply only (no incremental). Closing that gap is WP-1.6 backlog.

---

## CI / bitrot prevention

- **Script:** `scripts/ci/check-mistralrs-infer-build.sh` — `cargo check` + small unit tests (no model download).
- **Workflow:** `.github/workflows/mistralrs-infer.yml` — on PRs touching mistral-related paths, weekly cron, and `workflow_dispatch`.

---

## Backlog (post-WP-1.4)

| Tier | Item | Status |
|------|------|--------|
| **B** | Multimodal in-tree (WP-1.5) | RFC Proposed — implement after Accepted |
| **B** | Token streaming parity (HTTP provider SSE, Discord standard turns) | WP-1.6 extension |
| **A** | Per-turn which-backend metrics | **Shipped:** `GET /api/stack-status` → `llm_last_completion`, `llm_completion_totals` |
| **C** | MCP bridge / governance / swarms | Phase 7+ |

---

## Related docs

| Doc | Topic |
|-----|-------|
| [INFERENCE_PROFILES.md](INFERENCE_PROFILES.md) §2b | Metal, `HF_TOKEN`, failure modes, cascade precedence |
| [OPERATIONS.md](OPERATIONS.md) | Runtime ops |
| [WEB_API_REFERENCE.md](WEB_API_REFERENCE.md) | Stack status when mistral is primary |
| [METRICS.md](METRICS.md) §1c | `llm_last_completion` / `llm_completion_totals` |
| [rfcs/RFC-mistralrs-token-streaming.md](rfcs/RFC-mistralrs-token-streaming.md) | WP-1.6 SSE `text_delta` + Discord approval-path parity |
| [rfcs/RFC-mistralrs-multimodal-in-tree.md](rfcs/RFC-mistralrs-multimodal-in-tree.md) | WP-1.5 multimodal |
