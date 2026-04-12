# RFC — Token streaming (SSE / TextDelta) for Chump

**Status:** Accepted (Phase 1 — in-process mistral.rs path **implemented**; HTTP deferred)  
**Date:** 2026-04-12  
**Work package:** [HIGH_ASSURANCE_AGENT_PHASES.md](../HIGH_ASSURANCE_AGENT_PHASES.md) **WP-1.6**  
**Related:** [MISTRALRS_CAPABILITY_MATRIX.md](../MISTRALRS_CAPABILITY_MATRIX.md), [RFC-inference-backends.md](RFC-inference-backends.md), [`src/streaming_provider.rs`](../../src/streaming_provider.rs), [`src/mistralrs_provider.rs`](../../src/mistralrs_provider.rs), [`src/stream_events.rs`](../../src/stream_events.rs)

## Problem

The AxonerAI [`Provider`](https://crates.io/crates/axonerai) trait exposes only **`complete`** (one-shot). The PWA and JSONL RPC path already emit [`AgentEvent`](../../src/stream_events.rs) over SSE/stdout, but **model output** was effectively **buffered** until the full completion returned (plus **Thinking** keepalives from [`StreamingProvider`](../../src/streaming_provider.rs)).

Upstream **mistral.rs** supports **`Model::stream_chat_request`** with chunk-style [`Response::Chunk`](https://github.com/EricLBuehler/mistral.rs) / **`Done`**.

## Decision

1. **Do not** extend the external **`axonerai::Provider`** trait in this iteration (would require a semver bump and coordination across all provider impls).
2. **Implement** optional **true text streaming** for **in-process mistral.rs** only:
   - Env **`CHUMP_MISTRALRS_STREAM_TEXT_DELTAS=1`** (or `true`).
   - [`MistralRsProvider::complete_with_text_deltas`](../../src/mistralrs_provider.rs) uses **`stream_chat_request`**, maps chunk text to **`AgentEvent::TextDelta`**, final **`Done`** → the same completion payload shape as non-streaming **`send_chat_request`** (axonerai; tools + stop reasons preserved).
   - [`build_provider_with_mistral_stream`](../../src/provider_cascade.rs) returns a shared [`Arc<MistralRsProvider>`](../../src/mistralrs_provider.rs) for web/RPC and Discord tool-approval turns; [`StreamingProvider::new_with_mistral_stream`](../../src/streaming_provider.rs) invokes the streaming path when env is set.
   - When streaming succeeds, **`TextComplete` is omitted** (client should assemble from **`text_delta`** + **`turn_complete.full_text`**).
3. **Deferred:** OpenAI-compatible **HTTP** streaming (Ollama / vLLM / cascade **`LocalOpenAIProvider`**) — needs `reqwest` SSE parsing and/or shared abstraction; **`mistralrs serve`** remains the sidecar option for HTTP streaming without Chump changes.
4. **Discord (tool-approval path):** Uses the same [`StreamingProvider`](../../src/streaming_provider.rs) + **`mistral_for_stream`** as web/RPC when **`mistralrs-infer`** is enabled, so in-process mistral respects **`CHUMP_MISTRALRS_STREAM_TEXT_DELTAS`**. The handler still only **displays** the final reply from **`TurnComplete`** (no live **`text_delta`** in the channel). **Standard** Discord turns (no approval tools) still use [`axonerai::Agent`](https://crates.io/crates/axonerai) without **`StreamingProvider`**.

## Verification

- `cargo test -p rust-agent --workspace` (default features).
- `cargo clippy -p rust-agent --features mistralrs-infer -- -D warnings`.
- Manual: PWA chat with **`mistralrs-infer`** build + mistral env + **`CHUMP_MISTRALRS_STREAM_TEXT_DELTAS=1`** — SSE should include **`text_delta`** events.

## Changelog

| Date | Change |
|------|--------|
| 2026-04-12 | RFC **Accepted**; mistral in-process **TextDelta** path merged (**WP-1.6**). |
| 2026-04-12 | Discord **tool-approval** path wraps **`StreamingProvider`** (parity with web/RPC for mistral streaming env); UI still final-text only. |
