---
doc_tag: log
owner_gap:
last_audited: 2026-04-25
---

# Next-Gen Competitive Intelligence

Landscape of next-generation AI agent systems and where Chump stands relative to them. Primary reference: the detailed analysis in [book/src/hermes-competitive-roadmap.md](../book/src/hermes-competitive-roadmap.md).

## Primary competitor: Hermes (NousResearch)

[hermes-agent](https://github.com/NousResearch/hermes-agent) is the most architecturally comparable open-source agent system.

**Hermes strengths:**
- **Skills system** — self-improvement loop that writes reusable `SKILL.md` procedures after completing 5+ tool-call tasks (procedural memory)
- **Plugin architecture** — three discovery sources, `plugin.yaml` metadata, registry-based auto-discovery
- **18+ platform adapters** — Telegram, Discord, Slack, WhatsApp, Signal, Matrix, Mattermost, Email, SMS, and more
- **6 execution backends** — local, Docker, SSH, Daytona, Modal, Singularity
- **Voice/vision/browser** — image paste, browser automation (Browserbase, Chrome CDP), TTS providers

**Hermes weaknesses (Chump's attack surface):**
- No entity resolution in memory (can't link "Alice" with "my coworker Alice")
- Keyword-only cross-session search — FTS5 only, no semantic retrieval
- ~1,300 token hot-memory budget, hard cap on `MEMORY.md` + `USER.md`
- No confidence tracking or belief state — curation by agent judgment
- No empirical benchmarks — capability claims without measurement
- Python install friction (`curl | bash`, `uv`, pip, env drift)

**Where Chump wins today:**
- Memory graph with Personalized PageRank (entity resolution, graph traversal)
- FTS5 + semantic + graph RRF retrieval (no keyword-only limitation)
- Enriched memory schema: confidence, expiry, verified, sensitivity, memory_type
- Consciousness framework: surprise tracker, neuromodulation, belief state, precision controller
- Speculative execution with belief-state rollback
- Property-based eval harness with regression detection in DB
- Single Rust binary — `cargo build --release`, no Python env drift
- Empirical A/B results with Wilson 95% CIs

## Roadmap to close Hermes's gaps

See [book/src/hermes-competitive-roadmap.md](../book/src/hermes-competitive-roadmap.md) for the full phase-by-phase plan. Key items:

**Phase 1 (6–8 weeks, close standout UX gaps):**
1. **Skills system** — `src/skills.rs` + brain-relative `chump-brain/skills/<name>/SKILL.md`
2. **Plugin architecture** — user-dir + project-dir + pip entry points discovery
3. **Context engine pluggability** — swap compression/retrieval strategies
4. **Additional platform adapters** — beyond Discord/Slack/web

**Phase 2 (surpass on differentiated axes):**
- Consciousness-as-feature: expose belief state, precision regime, surprisal EMA in the UI
- Memory graph as user-visible knowledge graph (browser, export)
- Empirical research hub: public benchmark results, community replication

## Other systems to watch

| System | Differentiator | Watch for |
|--------|---------------|-----------|
| **AutoGen (Microsoft)** | Multi-agent conversation graphs | Multi-agent coordination patterns |
| **LangGraph** | Stateful graph execution | Stateful tool orchestration primitives |
| **CrewAI** | Role-based agent teams | Delegation and task routing patterns |
| **Open Interpreter** | Natural language OS control | Shell tool UX patterns |
| **Cognition Devin** | End-to-end software engineering | Long-horizon coding autonomy |

## See Also

- [Hermes Competitive Roadmap](../book/src/hermes-competitive-roadmap.md)
- [Chump to Champ](CHUMP_TO_CHAMP.md)
- [Roadmap](ROADMAP.md)
