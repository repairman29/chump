# Chump — documentation index

## Core Identity

| Document | Purpose |
|----------|---------|
| [NORTH_STAR.md](NORTH_STAR.md) | Founding vision: why Chump exists, first-run experience target, and what every decision is measured against |
| [CHUMP_PROJECT_BRIEF.md](CHUMP_PROJECT_BRIEF.md) | Project focus, conventions, cognitive-architecture findings, and agent guidance (subordinate to NORTH_STAR) |
| [RED_LETTER.md](RED_LETTER.md) | Cold Water — adversarial weekly review: no praise, just what is broken and what is being avoided |

## Architecture

| Document | Purpose |
|----------|---------|
| [ARCHITECTURE.md](ARCHITECTURE.md) | System architecture reference |
| [CHUMP_TO_COMPLEX.md](CHUMP_TO_COMPLEX.md) | Cognitive architecture vision, empirical status, and frontier research roadmap |
| [RUST_MODULE_MAP.md](RUST_MODULE_MAP.md) | Module-by-module crate map |
| [RUST_CODEBASE_PATTERNS.md](RUST_CODEBASE_PATTERNS.md) | Idiomatic patterns used in this codebase |
| [RUST_INFRASTRUCTURE.md](RUST_INFRASTRUCTURE.md) | Tower, tracing, proc macro, inventory, typestate, pool, notify |
| [CRATES_EXTRACTION_PLAN.md](CRATES_EXTRACTION_PLAN.md) | Living tracker for extracting standalone publishable crates from the monolith |
| [ADR-001-transactional-tool-speculation.md](ADR-001-transactional-tool-speculation.md) | Speculative execution rollback design |
| [ADR-002-mistralrs-structured-output-spike.md](ADR-002-mistralrs-structured-output-spike.md) | mistral.rs structured output decision |
| [ADR-003-pwa-dashboard-fe-gate.md](ADR-003-pwa-dashboard-fe-gate.md) | PWA dashboard architecture gate |
| [ADR-004-coord-blackboard-v2.md](ADR-004-coord-blackboard-v2.md) | NATS KV distributed blackboard — coordination v2 target architecture |

See [`rfcs/`](rfcs/) for draft proposals: inference backends, fleet workspace merge, mistral.rs multimodal, MCP tools, remote runner, token streaming, MCP sandbox scan.

## Research & Eval

| Document | Purpose |
|----------|---------|
| [CONSCIOUSNESS_AB_RESULTS.md](CONSCIOUSNESS_AB_RESULTS.md) | Raw A/B study data, per-cell forensics, and cross-family judge results (EVAL-001 through EVAL-025) |
| [research/consciousness-framework-paper.md](research/consciousness-framework-paper.md) | Research paper: Scaffolding U-curve, neuromodulation ablation, hallucination channel methodology |
| [research/RESEARCH_COMMUNITY.md](research/RESEARCH_COMMUNITY.md) | How to contribute to the live research study |
| [METRICS.md](METRICS.md) | CIS, phi proxy, surprisal threshold — exact computation from DB/logs |
| [NEUROMODULATION_HEURISTICS.md](NEUROMODULATION_HEURISTICS.md) | DA/NA/5HT tuning guide |
| [RETRIEVAL_EVAL_HARNESS.md](RETRIEVAL_EVAL_HARNESS.md) | Honest evaluation boundaries for holographic workspace and blackboard retrieval |
| [INTENT_CALIBRATION.md](INTENT_CALIBRATION.md) | Repeatable harness for evaluating intent-to-action mapping accuracy |
| [BATTLE_QA.md](BATTLE_QA.md) | 500-query battle QA test suite: run until all pass |
| [BATTLE_QA_FAILURES.md](BATTLE_QA_FAILURES.md) | Documented failure cases from the last battle QA run |
| [BATTLE_QA_SELF_FIX.md](BATTLE_QA_SELF_FIX.md) | Self-healing procedure: how Chump fixes its own battle QA failures |
| [BENCHMARKS.md](BENCHMARKS.md) | Public performance benchmarks, reproducible locally |
| [MISTRALRS_BENCHMARKS.md](MISTRALRS_BENCHMARKS.md) | mistral.rs end-to-end wall-time benchmarks by hardware |
| [MARKET_RESEARCH_EVIDENCE_LOG.md](MARKET_RESEARCH_EVIDENCE_LOG.md) | Blind market research evidence log (B-session records and interview stubs) |
| [eval/EVAL-010-labels.md](eval/EVAL-010-labels.md) | Human-labeled fixture subset for EVAL-010 |
| [eval/TEST_BACKLOG.md](eval/TEST_BACKLOG.md) | What should be measured but currently is not |

## Operations

| Document | Purpose |
|----------|---------|
| [EXTERNAL_GOLDEN_PATH.md](EXTERNAL_GOLDEN_PATH.md) | Full setup walkthrough for new users (the canonical first-run path) |
| [OPERATIONS.md](OPERATIONS.md) | Run modes, env vars, heartbeats, roles |
| [SCRIPTS_REFERENCE.md](SCRIPTS_REFERENCE.md) | Every script in `scripts/` with descriptions, flags, and key env vars |
| [AUTOMATION_SNIPPETS.md](AUTOMATION_SNIPPETS.md) | Copy-paste cron/launchd snippets for headless Chump |
| [HEARTBEAT_IMPROVEMENTS.md](HEARTBEAT_IMPROVEMENTS.md) | Ways to improve heartbeat round success rate |
| [FLEET_ROLES.md](FLEET_ROLES.md) | Fleet roles: Farmer Brown, Sentinel, Mabel, etc. |
| [INFERENCE_STABILITY.md](INFERENCE_STABILITY.md) | Troubleshooting timeouts, OOM, model flap; model flap drill |
| [INFERENCE_PROFILES.md](INFERENCE_PROFILES.md) | Canonical port assignments and model profiles |
| [EXECUTION_BACKENDS.md](EXECUTION_BACKENDS.md) | Ollama, vLLM, mistral.rs backend comparison |
| [PROVIDER_CASCADE.md](PROVIDER_CASCADE.md) | Provider cascade configuration |
| [LATENCY_ENVELOPE.md](LATENCY_ENVELOPE.md) | Measured latency baselines and optimization layers |
| [PERFORMANCE.md](PERFORMANCE.md) | Profiling and performance tuning |
| [STEADY_RUN.md](STEADY_RUN.md) | Long-run stability configuration |
| [MISTRALRS_AGENT_POWER_PATH.md](MISTRALRS_AGENT_POWER_PATH.md) | mistral.rs inference benchmarks and A/B modes |
| [MISTRALRS_CAPABILITY_MATRIX.md](MISTRALRS_CAPABILITY_MATRIX.md) | mistral.rs feature support matrix |
| [OLLAMA_SPEED.md](OLLAMA_SPEED.md) | Ollama speed tuning for Mac |
| [STORAGE_AND_ARCHIVE.md](STORAGE_AND_ARCHIVE.md) | Disk hygiene, git maintenance, cold export |
| [CHUMP_BRAIN.md](CHUMP_BRAIN.md) | Brain directory: external repos, projects, quick capture |
| [MEMORY_GRAPH_VS_FTS5.md](MEMORY_GRAPH_VS_FTS5.md) | When to use memory graph vs FTS5 search |
| [CONTEXT_PRECEDENCE.md](CONTEXT_PRECEDENCE.md) | How context sections are assembled and prioritized |

## Integrations & Tools

| Document | Purpose |
|----------|---------|
| [ACP.md](ACP.md) | Agent Client Protocol — editor integration (Zed, JetBrains) |
| [DISCORD_CONFIG.md](DISCORD_CONFIG.md) | Discord bot setup and configuration |
| [DISCORD_TROUBLESHOOTING.md](DISCORD_TROUBLESHOOTING.md) | Discord won't start / won't reply / DMs-only — fix guide |
| [A2A_DISCORD.md](A2A_DISCORD.md) | Agent-to-agent Discord messaging |
| [MESSAGING_ADAPTERS.md](MESSAGING_ADAPTERS.md) | Messaging adapter architecture |
| [INTENT_ACTION_PATTERNS.md](INTENT_ACTION_PATTERNS.md) | Intent-to-action pattern guide for the Discord bot and Cursor |
| [BROWSER_AUTOMATION.md](BROWSER_AUTOMATION.md) | Browser automation tool — CDP wrapper for dynamic pages and login flows |
| [WEB_API_REFERENCE.md](WEB_API_REFERENCE.md) | All `/api/` routes: health, chat, tasks, approval, uploads, pilot export |
| [RPC_MODE.md](RPC_MODE.md) | Headless stdin/stdout JSONL RPC mode for automation drivers |
| [TOOL_APPROVAL.md](TOOL_APPROVAL.md) | Tool approval gates and policy |
| [WASM_TOOLS.md](WASM_TOOLS.md) | WASM sandboxed tool lane |
| [PLUGIN_DEVELOPMENT.md](PLUGIN_DEVELOPMENT.md) | Writing new tools and plugins |
| [POLICY-sandbox-tool-routing.md](POLICY-sandbox-tool-routing.md) | Sandbox tool routing policy (INFRA-001c) |
| [tools_index.md](tools_index.md) | All registered tools with descriptions |
| [FTUE_USER_PROFILE.md](FTUE_USER_PROFILE.md) | Spec for first-run experience and three-layer user profile system (PRODUCT-003/004) |

## Gaps & Coordination

| Document | Purpose |
|----------|---------|
| [ROADMAP.md](ROADMAP.md) | What to work on next — single source of truth for the prioritized backlog |
| [AGENT_COORDINATION.md](AGENT_COORDINATION.md) | Multi-agent coordination: leases, worktrees, failure modes, five-job pre-commit spec |
| [CHUMP_CURSOR_FLEET.md](CHUMP_CURSOR_FLEET.md) | Cursor CLI (`agent`), IDE subagents / fleet handoffs, and safe parallel work with Chump |
| [SESSION_2026-04-18_SYNTHESIS.md](SESSION_2026-04-18_SYNTHESIS.md) | 36-hour autonomous loop synthesis: what shipped, what was learned, where to pick up |
| [syntheses/](syntheses/README.md) | All session synthesis documents; template and reading order |

## Archive

| Document | Purpose |
|----------|---------|
| [archive/](archive/README.md) | Historical and superseded material; runtime/disk archives described in STORAGE_AND_ARCHIVE.md |

---

*80+ markdown files under `docs/` (growing). For what to work on next: [ROADMAP.md](ROADMAP.md). For the founding vision: [NORTH_STAR.md](NORTH_STAR.md).*
