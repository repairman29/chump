---
doc_tag: canonical
owner_gap:
last_audited: 2026-05-12
---

# Chump — documentation index

## Core Identity

| Document | Purpose |
|----------|---------|
| [NORTH_STAR.md](strategy/NORTH_STAR.md) | Founding vision: why Chump exists, first-run experience target, and what every decision is measured against |
| [CHUMP_PROJECT_BRIEF.md](briefs/CHUMP_PROJECT_BRIEF.md) | Project focus, conventions, cognitive-architecture findings, and agent guidance (subordinate to NORTH_STAR) |
| [RED_LETTER.md](RED_LETTER.md) | Cold Water — adversarial weekly review: no praise, just what is broken and what is being avoided |

## Architecture

| Document | Purpose |
|----------|---------|
| [ARCHITECTURE.md](architecture/ARCHITECTURE.md) | System architecture reference |
| [CHUMP_TO_CHAMP.md](strategy/CHUMP_TO_CHAMP.md) | Chump-to-Champ roadmap: cognitive architecture vision, empirical status, and frontier research direction |
| [RUST_MODULE_MAP.md](architecture/RUST_MODULE_MAP.md) | Module-by-module crate map |
| [RUST_CODEBASE_PATTERNS.md](architecture/RUST_CODEBASE_PATTERNS.md) | Idiomatic patterns used in this codebase |
| [RUST_INFRASTRUCTURE.md](architecture/RUST_INFRASTRUCTURE.md) | Tower, tracing, proc macro, inventory, typestate, pool, notify |
| [CRATES_EXTRACTION_PLAN.md](process/CRATES_EXTRACTION_PLAN.md) | Living tracker for extracting standalone publishable crates from the monolith |
| [ADR-001-transactional-tool-speculation.md](architecture/ADR-001-transactional-tool-speculation.md) | Speculative execution rollback design |
| [ADR-002-mistralrs-structured-output-spike.md](architecture/ADR-002-mistralrs-structured-output-spike.md) | mistral.rs structured output decision |
| [ADR-004-coord-blackboard-v2.md](architecture/ADR-004-coord-blackboard-v2.md) | NATS KV distributed blackboard — coordination v2 target architecture |

See [`rfcs/`](rfcs/) for draft proposals: inference backends, fleet workspace merge, mistral.rs multimodal, MCP tools, remote runner, token streaming, MCP sandbox scan.

## Research & Eval

| Document | Purpose |
|----------|---------|
| [OOPS.md](operations/OOPS.md) | Oops log: broken instruments, reframes, and retractions (keeps Findings uncluttered) |
| [research/RESEARCH_COMMUNITY.md](research/RESEARCH_COMMUNITY.md) | How to contribute to the live research study |
| [METRICS.md](operations/METRICS.md) | CIS, phi proxy, surprisal threshold — exact computation from DB/logs |
| [NEUROMODULATION_HEURISTICS.md](research/NEUROMODULATION_HEURISTICS.md) | DA/NA/5HT tuning guide |
| [RETRIEVAL_EVAL_HARNESS.md](operations/RETRIEVAL_EVAL_HARNESS.md) | Honest evaluation boundaries for holographic workspace and blackboard retrieval |
| [BENCHMARKS.md](operations/BENCHMARKS.md) | Public performance benchmarks, reproducible locally |
| [MARKET_RESEARCH_EVIDENCE_LOG.md](research/MARKET_RESEARCH_EVIDENCE_LOG.md) | Blind market research evidence log (B-session records and interview stubs) |
| [eval/EVAL-010-labels.md](eval/EVAL-010-labels.md) | Human-labeled fixture subset for EVAL-010 |
| [eval/TEST_BACKLOG.md](eval/TEST_BACKLOG.md) | What should be measured but currently is not |

## Operations

| Document | Purpose |
|----------|---------|
| [USER_GUIDE.md](USER_GUIDE.md) | End-user guide: workflows, model recommendations, common tasks, troubleshooting (non-developer audience) |
| [PWA_USER_GUIDE.md](PWA_USER_GUIDE.md) | PWA web interface: gap queue, dispatch, workflow monitoring, troubleshooting (EFFECTIVE-016) |
| [EXTERNAL_GOLDEN_PATH.md](process/EXTERNAL_GOLDEN_PATH.md) | Full setup walkthrough for new users (the canonical first-run path) |
| [OPERATIONS.md](operations/OPERATIONS.md) | Run modes, env vars, heartbeats, roles |
| [SCRIPTS_REFERENCE.md](api/SCRIPTS_REFERENCE.md) | Every script in `scripts/` with descriptions, flags, and key env vars |
| [AUTOMATION_SNIPPETS.md](operations/AUTOMATION_SNIPPETS.md) | Copy-paste cron/launchd snippets for headless Chump |
| [FLEET_ROLES.md](architecture/FLEET_ROLES.md) | Fleet roles: Farmer Brown, Sentinel, Mabel, etc. |
| [INFERENCE_STABILITY.md](operations/INFERENCE_STABILITY.md) | Troubleshooting timeouts, OOM, model flap; model flap drill |
| [INFERENCE_PROFILES.md](operations/INFERENCE_PROFILES.md) | Canonical port assignments and model profiles |
| [EXECUTION_BACKENDS.md](architecture/EXECUTION_BACKENDS.md) | Ollama, vLLM, mistral.rs backend comparison |
| [PROVIDER_CASCADE.md](architecture/PROVIDER_CASCADE.md) | Provider cascade configuration |
| [LATENCY_ENVELOPE.md](operations/LATENCY_ENVELOPE.md) | Measured latency baselines and optimization layers |
| [PERFORMANCE.md](operations/PERFORMANCE.md) | Profiling and performance tuning |
| [STEADY_RUN.md](operations/STEADY_RUN.md) | Long-run stability configuration |
| [MISTRALRS.md](architecture/MISTRALRS.md) | mistral.rs consolidated reference (matrix + benchmarks + agent power path) |
| [OLLAMA_SPEED.md](howto/OLLAMA_SPEED.md) | Ollama speed tuning for Mac |
| [STORAGE_AND_ARCHIVE.md](operations/STORAGE_AND_ARCHIVE.md) | Disk hygiene, git maintenance, cold export |
| [CHUMP_BRAIN.md](architecture/CHUMP_BRAIN.md) | Brain directory: external repos, projects, quick capture |
| [MEMORY_GRAPH_VS_FTS5.md](architecture/MEMORY_GRAPH_VS_FTS5.md) | When to use memory graph vs FTS5 search |
| [CONTEXT_PRECEDENCE.md](architecture/CONTEXT_PRECEDENCE.md) | How context sections are assembled and prioritized |

## Integrations & Tools

| Document | Purpose |
|----------|---------|
| [ACP.md](architecture/ACP.md) | Agent Client Protocol — editor integration (Zed, JetBrains) |
| [ACP_CAPABILITY_COMPARISON.md](architecture/ACP_CAPABILITY_COMPARISON.md) | ACP capability comparison vs other registry agents (audited 2026-05-13) |
| [DISCORD_CONFIG.md](howto/DISCORD_CONFIG.md) | Discord bot setup and configuration |
| [DISCORD_TROUBLESHOOTING.md](operations/DISCORD_TROUBLESHOOTING.md) | Discord won't start / won't reply / DMs-only — fix guide |
| [A2A_DISCORD.md](process/A2A_DISCORD.md) | Agent-to-agent Discord messaging |
| [MESSAGING_ADAPTERS.md](architecture/MESSAGING_ADAPTERS.md) | Messaging adapter architecture |
| [INTENT_ACTION_PATTERNS.md](architecture/INTENT_ACTION_PATTERNS.md) | Intent-to-action pattern guide for the Discord bot and Cursor |
| [BROWSER_AUTOMATION.md](operations/BROWSER_AUTOMATION.md) | Browser automation tool — CDP wrapper for dynamic pages and login flows |
| [WEB_API_REFERENCE.md](api/WEB_API_REFERENCE.md) | All `/api/` routes: health, chat, tasks, approval, uploads, pilot export |
| [TOOL_APPROVAL.md](operations/TOOL_APPROVAL.md) | Tool approval gates and policy |
| [WASM_TOOLS.md](architecture/WASM_TOOLS.md) | WASM sandboxed tool lane |
| [PLUGIN_DEVELOPMENT.md](howto/PLUGIN_DEVELOPMENT.md) | Writing new tools and plugins |
| [POLICY-sandbox-tool-routing.md](architecture/POLICY-sandbox-tool-routing.md) | Sandbox tool routing policy (INFRA-001c) |
| [tools_index.md](api/tools_index.md) | All registered tools with descriptions |
| [FTUE_USER_PROFILE.md](process/FTUE_USER_PROFILE.md) | Spec for first-run experience and three-layer user profile system (PRODUCT-003/004) |

## Gaps & Coordination

| Document | Purpose |
|----------|---------|
| [ROADMAP.md](ROADMAP.md) | What to work on next — single source of truth for the prioritized backlog |
| [AGENT_COORDINATION.md](process/AGENT_COORDINATION.md) | Multi-agent coordination: leases, worktrees, failure modes, five-job pre-commit spec |
| [CHUMP_CURSOR_FLEET.md](process/CHUMP_CURSOR_FLEET.md) | Cursor CLI (`agent`), IDE subagents / fleet handoffs, and safe parallel work with Chump |
| [syntheses/](syntheses/README.md) | All session synthesis documents; template and reading order |

## Archive

| Document | Purpose |
|----------|---------|
| [archive/](archive/README.md) | Historical and superseded material; runtime/disk archives described in STORAGE_AND_ARCHIVE.md |

---

*80+ markdown files under `docs/` (growing). For what to work on next: [ROADMAP.md](ROADMAP.md). For the founding vision: [NORTH_STAR.md](strategy/NORTH_STAR.md).*
