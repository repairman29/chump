# Speculative decoding and in-process embeddings

This doc captures the **current state** and **implementation notes** for two Phase 1 items: speculative decoding (inference speed) and in-process embeddings (remove Python embed server). Both are optional improvements; the agent works without them.

---

## Speculative decoding

### What it is

**Speculative decoding** uses a small, fast “draft” model to propose several tokens, then a larger “target” model verifies (accept or reject) in one forward pass. When the draft is accurate, you get 1.5x–3x speedup with no quality loss; when wrong, the target corrects. No change to the agent’s API or prompts—this is a server/inference configuration.

### Current state

- We use **vLLM-MLX** (e.g. 30B 4-bit) as the OpenAI-compatible endpoint.
- **Upstream vLLM** supports speculative decoding: draft models (small LM, MLP, or Eagle3), n-gram lookup; see [vLLM speculative decoding](https://docs.vllm.ai/en/latest/features/speculative_decoding/) and [Speculators v0.3.0](https://blog.vllm.ai/2025/12/13/speculators-v030.html). vLLM-MLX may expose the same or a subset; check the vLLM-MLX repo and release notes for MLX-specific flags.
- **Today:** No speculative decoding in our config; single model only.

### How to add it (when the stack supports it)

1. **Check vLLM-MLX / vLLM docs** for:
   - Enabling speculative decoding.
   - Specifying a draft model (e.g. small 1B–3B) and the target model (e.g. 30B).
2. **Config sketch:** Either:
   - **Server-side:** Start vLLM with a flag or config that sets draft + target (e.g. `--speculative-model …` or equivalent).
   - **Agent-side:** Optional env or config (e.g. `CHUMP_SPECULATIVE_DRAFT_URL` or a second base URL) only if the server requires the client to point at a separate draft endpoint; many implementations handle both models inside the same server.
3. **Document:** In [ROADMAP.md](ROADMAP.md) and this doc, note the exact flags or config that were used so others can reproduce.
4. **If not supported on MLX:** Leave as “future work” in the roadmap; no agent code change required until the inference stack supports it.

### References

- [vLLM Speculative Decoding](https://docs.vllm.ai/en/latest/features/speculative_decoding/) — draft models (LM, MLP, Eagle3), n-gram.
- [Speculators v0.3.0](https://blog.vllm.ai/2025/12/13/speculators-v030.html) — Eagle3 training and vLLM integration.
- Blueprint: _Enhancing Local AI Agents_ — “speculative decoding (draft + target model) for 1.5x–3x speedup without quality loss.”

---

## In-process embeddings

### What it is

Today, **embeddings** are produced by a **separate Python embed server** (sentence-transformers, e.g. `all-MiniLM-L6-v2`) on port 18765. The agent HTTP-calls it to embed the user message and each new memory; vectors are stored in `sessions/chump_memory_embeddings.json` (or used from the SQLite-backed path when applicable). **In-process embeddings** means the Rust agent loads a small embedding model (e.g. ONNX/Candle/Burn) and runs inference inside the same process, so we can remove the Python server for default deployments.

### Current state

- **Embed server:** Optional; when running, Chump uses it for semantic recall and backfill.
- **Fallback:** If the server is down or disabled, recall is keyword-only (FTS5 when using SQLite, or in-memory word match on JSON).
- **Hybrid recall:** When both SQLite and the embed server are available, we use **RRF** (reciprocal rank fusion) to merge keyword (FTS5) and semantic (cosine) results. See [CHUMP_SMART_MEMORY.md](CHUMP_SMART_MEMORY.md).

### Why in-process

- **Fewer moving parts:** No separate Python process or port to start/monitor.
- **Single binary (or binary + model file):** Easier distribution and launch.
- **Latency:** No HTTP round-trip for each embed (user message + backfill); can be faster for small batches.

### Tradeoffs to document when prototyping

| Concern          | Notes                                                                                                                                                             |
| ---------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Binary size**  | ONNX runtime, Candle, or Burn will increase the Rust binary (or add a separate native lib). Measure before/after.                                                 |
| **Portability**  | Ensure the chosen crate works on macOS (including ARM) and any other target platforms.                                                                            |
| **Model format** | all-MiniLM-L6-v2–class models: export to ONNX or use a format the Rust stack can load.                                                                            |
| **Speed**        | Compare: one HTTP call to Python vs one in-process forward. For a single sentence, in-process can be faster; for large backfill, batch size and threading matter. |
| **Memory**       | Embedding model in process adds tens to low hundreds of MB; acceptable if the agent is already the only heavy process on a dev machine.                           |

### In-process embeddings (implemented, optional)

When built with the **`inprocess-embed`** feature, the agent can embed text locally using the **fastembed** crate (all-MiniLM-L6-v2, same as the Python server). No embed server or `CHUMP_EMBED_URL` is required.

- **Build:** `cargo build --features inprocess-embed` (or add to your release profile).
- **Behavior:** If `CHUMP_EMBED_URL` is unset or empty, the agent uses in-process embedding; otherwise it uses the HTTP server. Set `CHUMP_EMBED_INPROCESS=1` to prefer in-process even when `CHUMP_EMBED_URL` is set.
- **Model:** Downloaded on first use (via fastembed cache). Override cache with `CHUMP_EMBED_CACHE_DIR`.
- **Compatibility:** Vectors are compatible with existing `chump_memory_embeddings.json` and the Python embed server (same model class).

### Other implementation options (Rust)

- **ort** (ONNX Runtime): Used by fastembed under the hood.
- **candle** (Hugging Face): Native Rust; alternative if you need a different model or backend.
- **burn**: Another Rust ML framework; evaluate if needed.

### How to prototype

1. **Pick one stack** (e.g. `ort` or `candle`) and add it as an optional dependency (feature-flagged if desired).
2. **Load a small encoder** (e.g. all-MiniLM-L6-v2 in the format the stack expects) at agent startup or on first use.
3. **Replace** the HTTP call to the embed server with a local `embed_text(text: &str) -> Vec<f32>` (and optionally `embed_texts` for batch) that runs in-process.
4. **Keep** the same recall pipeline: vectors still align with memory entries (by index or by id when using SQLite); RRF and cosine similarity logic stay the same.
5. **Config:** e.g. `CHUMP_EMBED_URL` unset or empty = use in-process; set = use HTTP server (allows A/B or fallback).
6. **Document** in this file and CHUMP_SMART_MEMORY.md: chosen crate, model name/format, binary size delta, and any platform caveats.

### References

- [CHUMP_SMART_MEMORY.md](CHUMP_SMART_MEMORY.md) — Current memory and embed server.
- [ROADMAP.md](ROADMAP.md) — Phase 1 (memory and embeddings).
