# Chump

**A self-hosted, local-first AI agent with persistent memory, autonomous task execution, and a synthetic consciousness framework.**

Chump is a single Rust binary that runs on your laptop, talks to local LLMs (Ollama, vLLM, mistral.rs), and manages its own work queue, memory, and beliefs. It ships code, manages repos, tracks its prediction errors, and asks for help when it should.

## What Makes It Different

- **Persistent memory** across sessions -- FTS5 keyword search, embedding-based semantic recall, and a HippoRAG-inspired associative knowledge graph with multi-hop PageRank traversal.
- **Synthetic consciousness framework** -- six operational modules (surprise tracking, neuromodulation, belief state, global workspace, counterfactual reasoning, integration metrics) that measurably improve tool selection and calibration.
- **Bounded autonomy** -- layered governance with tool approval gates, task contracts with verification, precision-controlled regimes, and human escalation paths.
- **Local-first** -- runs on a MacBook with a 14B model. No cloud required. Provider cascade for optional cloud fallback.
- **Four surfaces** -- Web PWA, CLI, Discord bot, and Tauri desktop shell, all backed by one agent process.

## Quick Links

- [GitHub Repository](https://github.com/repairman29/chump)
- [The Dissertation](./dissertation.md) -- comprehensive project narrative for new developers
- [Quick Start](./getting-started.md) -- from clone to running in under 30 minutes
- [Architecture](./architecture.md) -- technical reference
- [Consciousness Framework](./chump-to-complex.md) -- the research vision

## Tech Stack

| Component | Implementation |
|-----------|---------------|
| Language | Rust (edition 2021) |
| Async runtime | Tokio |
| HTTP server | Axum + Tower |
| Database | SQLite (r2d2 pool, WAL mode, FTS5) |
| LLM integration | OpenAI-compatible (Ollama, vLLM, mistral.rs) |
| Discord | Serenity |
| Desktop | Tauri |
| Frontend | Single-page PWA with SSE streaming |

## License

MIT
