# Chump Roadmap

This roadmap aligns with the architectural blueprint **"Enhancing Local AI Agents"** (next-generation edge AI: scaling local-first autonomous agents). The blueprint covers six pillars; below we state where Chump is today and prioritized next steps per pillar, then group work into phases.

## Reference

- **Blueprint:** _Enhancing Local AI Agents_ (architectural blueprint for next-generation edge AI). Stored locally (e.g. `~/Downloads/Enhancing Local AI Agents.txt`); not in repo.
- **Chump today:** Rust agent, vLLM-MLX, local memory (SQLite + FTS5 + RRF hybrid recall, or JSON fallback; optional Python embed server or in-process fastembed via `--features inprocess-embed`), Discord + CLI, tools: run_cli, memory, calculator, optional wasm_calc and delegate (summarize, extract). See [CHUMP_IDENTITY.md](CHUMP_IDENTITY.md) and [BLOG_CHUMP_DEEP_DIVE.md](BLOG_CHUMP_DEEP_DIVE.md).

---

## 1. Systems-level foundation

**Blueprint:** Rust core, &lt;20MB idle, sub-10ms startup, schema-validated tool boundaries, no ambient authority.

**Current:** Done. Agent is Rust + AxonerAI; tool inputs validated via schemas; timeouts and output caps on CLI; optional allow/blocklist (`CHUMP_CLI_ALLOWLIST` / `CHUMP_CLI_BLOCKLIST`). Idle footprint under 20MB and startup sub-10ms are design targets (not CI-measured).

**Next:**

- Keep dependency set minimal; avoid pulling in heavy runtimes.
- When adding new tools, maintain trait-based registry and schema-only boundaries.

---

## 2. Native inference and speculative decoding

**Blueprint:** vLLM-MLX, continuous batching, prefix caching; speculative decoding (draft + target model) for 1.5x–3x speedup without quality loss.

**Current:** We use vLLM-MLX (30B 4-bit DWQ or smaller); server provides batching and prefix cache. No speculative decoding.

**Next:**

- Check vLLM-MLX (or upstream vLLM) for speculative decoding (draft model + target model).
- If supported: document or add optional config (e.g. second model, env or serve flag) for draft/target pair (e.g. small draft + 30B target). Implementation notes: [SPECULATIVE_AND_EMBEDDINGS.md](SPECULATIVE_AND_EMBEDDINGS.md).
- If not supported on MLX: note in docs as future work; prioritize when stack supports it.

---

## 3. Deterministic tool output (logit-level grammar)

**Blueprint:** Structured generation (llguidance / xgrammar) so tool-call JSON is always valid; no retry loops for malformed output.

**Current:** We send `tool_choice: "auto"` when tools are present so servers that support it (e.g. vLLM with `--enable-auto-tool-choice`) can use structured output. See [STRUCTURED_TOOL_OUTPUT.md](STRUCTURED_TOOL_OUTPUT.md). Malformed tool JSON is logged to stderr (tool name + parse error + args preview); we keep validation and fallback to empty object.

**Next:**

- If vLLM-MLX adds full tool-calling/structured output, our requests are already compatible.

---

## 4. Zero-latency hybrid memory

**Blueprint:** In-process vector search (sqlite-vec), FTS5, RRF fusion; native Rust embeddings (ort / candle / burn) instead of Python.

**Current:**

- **Memory backend:** Prefers SQLite (`sessions/chump_memory.db`) with FTS5 for keyword search; migrates from `sessions/chump_memory.json` on first use. Falls back to JSON when the DB path is not available.
- **Recall:** Keyword via FTS5 (or in-memory when JSON). When the optional Python embed server is running (port 18765) or in-process embeddings are used (build with `--features inprocess-embed`), **RRF** merges keyword and semantic results. Embeddings remain in `sessions/chump_memory_embeddings.json`. See [CHUMP_SMART_MEMORY.md](CHUMP_SMART_MEMORY.md).

**Next:**

- **Phase 1 (memory) — done for hybrid recall:** SQLite + FTS5 + RRF is implemented. Optional future: store vectors in SQLite via sqlite-vec for single-DB persistence and in-DB KNN.
- **Phase 1 (embeddings):** In-process fastembed implemented (optional feature `inprocess-embed`); Python embed server optional. Tradeoffs: [SPECULATIVE_AND_EMBEDDINGS.md](SPECULATIVE_AND_EMBEDDINGS.md).

---

## 5. WASM tool sandbox

**Blueprint:** wasmtime + WASI; capability-based tool execution; replace ambient `run_cli` with sandboxed tools so the model has no host authority by default.

**Current:** WASM tool runner runs a WASI module via the **wasmtime** CLI: stdin in, stdout/stderr out; no filesystem or network. One concrete tool **wasm_calc** (safe calculator) is registered when `wasmtime` is on PATH and `wasm/calculator.wasm` exists. See [WASM_TOOLS.md](WASM_TOOLS.md) and `wasm/calc-wasm/` for building the calculator WASM.

**Next:**

- Optional: in-process wasmtime (Rust API) instead of CLI for fewer dependencies and lower latency.
- Add more WASM tools (e.g. read-only file reader) following the same pattern; document complement vs run_cli.

---

## 6. Multi-agent swarm (orchestrator–worker and heartbeat)

**Blueprint:** Orchestrator–worker topology, deterministic state machine for routing, heartbeat pattern (lightweight poller, wake heavy model only when needed).

**Current:** Design doc [ORCHESTRATOR_WORKER.md](ORCHESTRATOR_WORKER.md). Delegated task types: **summarize**, **extract**. Set `CHUMP_DELEGATE=1` to register the `delegate` tool. Worker runs a single LLM completion (no tools). **Worker-specific model:** set `CHUMP_WORKER_API_BASE` and/or `CHUMP_WORKER_MODEL` to point the worker at a smaller/faster model (e.g. 7B on 8001); otherwise falls back to `OPENAI_API_BASE` / `OPENAI_MODEL`. Heartbeat: warm-the-ovens remains the on-demand wake.

**Next:**

- More task types (e.g. translate) with fixed worker prompts and payload schemas.
- **Parallel agents:** See [ROADMAP_PARALLEL_AGENTS.md](ROADMAP_PARALLEL_AGENTS.md) for the full plan (parallel workers in one turn, safe concurrent turns, multi-process).

---

## Phasing

| Phase       | Focus                  | Items                                                                                                                              |
| ----------- | ---------------------- | ---------------------------------------------------------------------------------------------------------------------------------- |
| **Phase 1** | Memory and inference   | Hybrid memory (SQLite + FTS5 + RRF); optional in-process embeddings (fastembed); speculative decoding (when vLLM-MLX supports it). |
| **Phase 2** | Safety and determinism | tool_choice: auto for servers that support it; WASM runner (wasmtime CLI) + wasm_calc tool.                                        |
| **Phase 3** | Multi-agent            | Design doc; delegate tool (summarize); heartbeat aligned with warm-the-ovens.                                                      |

Work in Phase 1 can be parallelized (memory vs inference). Phase 2 depends on a stable Phase 1. Phase 3 is explicitly later so the single-agent path stays simple and well-tested.

---

## Links

- [FULLY_ARMORED_VEHICLE.md](FULLY_ARMORED_VEHICLE.md) — Master checklist: arsenal we have + gaps (resilience, observability, security, recovery, kill switch, testing). Prioritized “add to arsenal” phases (FAV-1–FAV-6).
- [CHUMP_IDENTITY.md](CHUMP_IDENTITY.md) — Soul, tools, memory, logs.
- [CHUMP_PROJECT_BRIEF.md](CHUMP_PROJECT_BRIEF.md) — One-pager: what we're building, current focus, key docs. Keep updated so Chump (and humans) know the plan.
- [TEACHING_CHUMP_WHAT_WE_BUILD.md](TEACHING_CHUMP_WHAT_WE_BUILD.md) — How Chump learns the plan (as we execute + explicit brief/memory sync).
- [CHUMP_SMART_MEMORY.md](CHUMP_SMART_MEMORY.md) — Semantic and keyword memory, SQLite + FTS5, RRF, embed server.
- [SPECULATIVE_AND_EMBEDDINGS.md](SPECULATIVE_AND_EMBEDDINGS.md) — Speculative decoding and in-process embeddings (Phase 1 notes).
- [BLOG_CHUMP_DEEP_DIVE.md](BLOG_CHUMP_DEEP_DIVE.md) — Why Rust, MLX, and WASM direction.
- [STRUCTURED_TOOL_OUTPUT.md](STRUCTURED_TOOL_OUTPUT.md) — Tool-call structured output (Phase 2).
- [WASM_TOOLS.md](WASM_TOOLS.md) — WASM tool runner and wasm_calc (Phase 2).
- [ORCHESTRATOR_WORKER.md](ORCHESTRATOR_WORKER.md) — Orchestrator–worker design and delegate tool (Phase 3).
