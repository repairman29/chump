# Top-Tier Vision

Long-horizon technical vision for Chump — the architectural bets worth making when the foundations are stable. Overlaps with [ROADMAP_UNIVERSAL_POWER.md](ROADMAP_UNIVERSAL_POWER.md) (operational items) and [CHUMP_TO_COMPLEX.md](CHUMP_TO_COMPLEX.md) (cognitive architecture).

## Inference tier

**In-process inference** — Replace the HTTP hop with `mistral.rs` running in-process. Eliminates reqwest → axum latency per completion. `CHUMP_INFERENCE_BACKEND=mistralrs` already routes there; remaining work is ISQ quantization tuning. See [INFERENCE_PROFILES.md](INFERENCE_PROFILES.md) §2b.

**X-LoRA / AnyMoE** — Mixture-of-experts adapters for task-specialized model layers. Vision-only until a clear product need emerges; upstream builders have these.

**Fleet mesh inference** — 1B edge (Pixel/Pi), 7B mid-tier, 14B Mac. Routing by task complexity. See [INFERENCE_MESH.md](INFERENCE_MESH.md).

## Tool execution tier

**JIT WASM tools** — Compile user-defined tool logic to WASM at runtime. Pre-compiled modules ship today; JIT enables user-uploaded tool logic without redeploy. See [WASM_TOOLS.md](WASM_TOOLS.md).

**Full transactional speculation** — True per-tool rollback covering HTTP, SQLite, and Discord effects. Currently only repo-filesystem is sandboxed (`CHUMP_SANDBOX_SPECULATION=1`). Full transactional semantics require a dry-run executor per tool or a write-ahead log. See [ADR-001](ADR-001-transactional-tool-speculation.md).

**Managed browser (Firecrawl)** — Fully rendered JS-executing browser for `read_url`. Currently `read_url` fetches static HTML. V2 roadmap: `chromiumoxide` behind `--features browser-automation`. V3: Firecrawl API + Browserbase for stealth / session persistence.

## Memory tier

**Semantic memory search** — The FTS5 + graph + cross-encoder pipeline is production-ready. Top-tier: multi-hop reasoning over the memory graph, SAKE-style knowledge anchoring, and confidence-weighted retrieval with temporal decay.

**Active memory curation** — The LLM curator prunes, summarizes, and elevates memories by confidence today. Top-tier: scheduled adversarial memory review (hallucination auditing) and proactive gap identification ("I don't know X; query for it").

## Cognitive tier

**Stateless task decomposition** — Break long agent turns into checkpointed subtasks that restart from a snapshot on crash. Pairs with `chump_tasks` lease columns. Currently crashes lose all progress.

**Test-time-compute routing** — Route complex problems to extended thinking mode automatically based on task classification and uncertainty. `CHUMP_THINKING_XML` today is a static flag.

**eBPF observability** — Zero-overhead kernel-level tracing of tool syscalls without modifying agent code. Linux ≥ 5.8 required. Useful for the high-assurance posture audit trail that can't be tampered with by the agent.

## Platform tier

**MCP ecosystem bridge** — Generic MCP server registration so any MCP-compliant tool server works without a custom integration. RFC filed: [rfcs/RFC-wp23-mcp-sandboxscan-class.md](rfcs/RFC-wp23-mcp-sandboxscan-class.md).

**Homebrew distribution** — `brew install chump` or `brew install --cask chump` (GUI). Removes the git-clone onboarding step. COMP-010 in the open backlog.

**Fleet orchestration** — Self-dispatching meta-loop where Chump picks and assigns its own gaps. AUTO-013 is the MVP path.

## See Also

- [ROADMAP_UNIVERSAL_POWER.md](ROADMAP_UNIVERSAL_POWER.md) — operational items from this list
- [CHUMP_TO_COMPLEX.md](CHUMP_TO_COMPLEX.md) — cognitive architecture north star
- [INFERENCE_PROFILES.md](INFERENCE_PROFILES.md) — mistral.rs §2b
- [WASM_TOOLS.md](WASM_TOOLS.md) — current WASM tool architecture
