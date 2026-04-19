# Chump — documentation index

## Start here

| Document | Purpose |
|----------|---------|
| [EXTERNAL_GOLDEN_PATH.md](EXTERNAL_GOLDEN_PATH.md) | Full setup walkthrough for new users |
| [ARCHITECTURE.md](ARCHITECTURE.md) | System architecture reference |
| [CHUMP_PROJECT_BRIEF.md](CHUMP_PROJECT_BRIEF.md) | Project focus, conventions, and agent guidance |
| [OPERATIONS.md](OPERATIONS.md) | Run modes, env vars, heartbeats, roles |
| [ROADMAP.md](ROADMAP.md) | What to work on next (single source of truth) |

## Cognitive architecture and research

| Document | Purpose |
|----------|---------|
| [CHUMP_TO_COMPLEX.md](CHUMP_TO_COMPLEX.md) | Cognitive architecture vision, empirical status, and frontier roadmap |
| [CONSCIOUSNESS_AB_RESULTS.md](CONSCIOUSNESS_AB_RESULTS.md) | Raw A/B study data and per-cell forensics |
| [research/consciousness-framework-paper.md](research/consciousness-framework-paper.md) | Research paper: Scaffolding U-curve, neuromodulation ablation, hallucination channel |
| [research/RESEARCH_COMMUNITY.md](research/RESEARCH_COMMUNITY.md) | How to contribute to the live research study |
| [METRICS.md](METRICS.md) | CIS, phi proxy, surprisal threshold — exact computation from DB/logs |
| [NEUROMODULATION_HEURISTICS.md](NEUROMODULATION_HEURISTICS.md) | DA/NA/5HT tuning guide |

## Integration

| Document | Purpose |
|----------|---------|
| [ACP.md](ACP.md) | Agent Client Protocol — editor integration (Zed, JetBrains) |
| [DISCORD_CONFIG.md](DISCORD_CONFIG.md) | Discord bot setup and configuration |
| [A2A_DISCORD.md](A2A_DISCORD.md) | Agent-to-agent Discord messaging |
| [FLEET_ROLES.md](FLEET_ROLES.md) | Fleet roles: Farmer Brown, Sentinel, Mabel, etc. |
| [MESSAGING_ADAPTERS.md](MESSAGING_ADAPTERS.md) | Messaging adapter architecture |

## Inference and performance

| Document | Purpose |
|----------|---------|
| [INFERENCE_STABILITY.md](INFERENCE_STABILITY.md) | Troubleshooting timeouts, OOM, model flap |
| [INFERENCE_PROFILES.md](INFERENCE_PROFILES.md) | Canonical port assignments and model profiles |
| [EXECUTION_BACKENDS.md](EXECUTION_BACKENDS.md) | Ollama, vLLM, mistral.rs backend comparison |
| [PROVIDER_CASCADE.md](PROVIDER_CASCADE.md) | Provider cascade configuration |
| [LATENCY_ENVELOPE.md](LATENCY_ENVELOPE.md) | Measured latency baselines and optimization layers |
| [PERFORMANCE.md](PERFORMANCE.md) | Profiling and performance tuning |
| [STEADY_RUN.md](STEADY_RUN.md) | Long-run stability configuration |
| [MISTRALRS_AGENT_POWER_PATH.md](MISTRALRS_AGENT_POWER_PATH.md) | mistral.rs inference benchmarks and A/B modes |
| [MISTRALRS_CAPABILITY_MATRIX.md](MISTRALRS_CAPABILITY_MATRIX.md) | mistral.rs feature support matrix |

## Tools and governance

| Document | Purpose |
|----------|---------|
| [TOOL_APPROVAL.md](TOOL_APPROVAL.md) | Tool approval gates and policy |
| [WASM_TOOLS.md](WASM_TOOLS.md) | WASM sandboxed tool lane |
| [PLUGIN_DEVELOPMENT.md](PLUGIN_DEVELOPMENT.md) | Writing new tools and plugins |
| [tools_index.md](tools_index.md) | All registered tools with descriptions |

## Memory and context

| Document | Purpose |
|----------|---------|
| [CHUMP_BRAIN.md](CHUMP_BRAIN.md) | Brain directory: external repos, projects, quick capture |
| [MEMORY_GRAPH_VS_FTS5.md](MEMORY_GRAPH_VS_FTS5.md) | When to use memory graph vs FTS5 search |
| [CONTEXT_PRECEDENCE.md](CONTEXT_PRECEDENCE.md) | How context sections are assembled and prioritized |
| [STORAGE_AND_ARCHIVE.md](STORAGE_AND_ARCHIVE.md) | Disk hygiene, git maintenance, cold export |

## Rust codebase

| Document | Purpose |
|----------|---------|
| [RUST_MODULE_MAP.md](RUST_MODULE_MAP.md) | Module-by-module crate map |
| [RUST_CODEBASE_PATTERNS.md](RUST_CODEBASE_PATTERNS.md) | Idiomatic patterns used in this codebase |
| [RUST_INFRASTRUCTURE.md](RUST_INFRASTRUCTURE.md) | Tower, tracing, proc macro, inventory, typestate, pool, notify |
| [AGENT_COORDINATION.md](AGENT_COORDINATION.md) | Multi-agent coordination: leases, worktrees, failure modes |

## Architecture decision records

| Document | Purpose |
|----------|---------|
| [ADR-001-transactional-tool-speculation.md](ADR-001-transactional-tool-speculation.md) | Speculative execution rollback design |
| [ADR-002-mistralrs-structured-output-spike.md](ADR-002-mistralrs-structured-output-spike.md) | mistral.rs structured output decision |
| [ADR-003-pwa-dashboard-fe-gate.md](ADR-003-pwa-dashboard-fe-gate.md) | PWA dashboard architecture gate |

## RFCs

See [`rfcs/`](rfcs/) for draft proposals: inference backends, fleet workspace merge, mistral.rs multimodal, MCP tools, remote runner, token streaming.

---

*57 documents as of 2026-04-18. For what to work on next: [ROADMAP.md](ROADMAP.md).*
