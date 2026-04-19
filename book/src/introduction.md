# Chump

**A self-hosted, local-first AI agent with persistent memory, autonomous task execution, and a cognitive architecture under active empirical study.**

Chump is a single Rust binary that runs on your laptop, talks to local LLMs (Ollama, vLLM, mistral.rs), and manages its own work queue, memory, and beliefs. It ships code, manages repos, tracks its prediction errors, and asks for help when it should.

## What Makes It Different

- **Persistent memory** across sessions -- FTS5 keyword search, embedding-based semantic recall, and a HippoRAG-inspired associative knowledge graph with multi-hop PageRank traversal.
- **Cognitive architecture under study** -- nine subsystems (surprise tracker, belief state, blackboard/global workspace, neuromodulation, precision controller, memory graph, counterfactual reasoning, phi proxy, holographic workspace) wired into the agent loop and actively studied via A/B eval with multi-axis scoring and A/A controls. See [current empirical status](./research-paper.md) — findings are preliminary and research is ongoing.
- **Bounded autonomy** -- layered governance with tool approval gates, task contracts with verification, precision-controlled regimes, post-execution action verification for write tools, and human escalation paths.
- **Local-first** -- runs on a MacBook with a 14B model. No cloud required. Provider cascade for optional cloud fallback.
- **Structured perception layer** -- rule-based task classification, entity extraction, constraint detection, and risk assessment before the model sees the input.
- **Eval framework** -- property-based evaluation cases with regression detection, stored in SQLite for tracking across versions. A/B eval harness with Wilson 95% CIs and A/A noise-floor controls for cognitive architecture experiments.
- **Five surfaces** -- Web PWA, CLI, Discord bot, Tauri desktop shell, and ACP stdio server (`chump --acp`) for Zed/JetBrains editor-native integration, all backed by one agent process.

## Quick Links

- [GitHub Repository](https://github.com/repairman29/chump)
- [The Dissertation](./dissertation.md) -- technical thesis: architecture, 9 consciousness modules, ACP, lessons learned
- [Quick Start](./getting-started.md) -- from clone to running in under 30 minutes
- [Architecture](./architecture.md) -- technical reference
- [Cognitive Architecture & Research](./chump-to-complex.md) -- vision, empirical status, and frontier roadmap

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
