# Chump documentation index (master)

**Purpose:** Canonical table of contents for the full project in dossier order. Use this index to build or navigate the journal-style dossier and to ensure every part of the project is documented.

**Day-to-day navigation:** For run, roadmaps, brain, and Mabel see [README.md](README.md).

**How the dossier is built:** [DOSSIER.md](DOSSIER.md) is written section-by-section from this index: each dossier section has a short narrative plus "See [doc](...)" links to the library docs listed below.

---

## 0. Meta

How to use this index; repo layout.

| Document | Description |
|----------|-------------|
| [00-INDEX.md](00-INDEX.md) | This file: master index in dossier order. |
| [README.md](README.md) | Docs index: day-to-day navigation (run, roadmaps, brain, Mabel, reference). |
| [DOSSIER.md](DOSSIER.md) | Built report for external review; narrative + links to this library. |
| [SHOWCASE_AND_ACADEMIC_PACKET.md](SHOWCASE_AND_ACADEMIC_PACKET.md) | **Showcase + academic packet:** executive summary, evidence table, ethics, related work, Mac vs CI validation, time-boxed reading paths. |
| [WHITE_PAPER_COMPLETION_PLAN.md](WHITE_PAPER_COMPLETION_PLAN.md) | **PDF white papers:** phased plan to maximize bundled PDFs (content, mermaid, LaTeX, CI, profiles). |
| [README.md](../README.md) | Repo root: quick start, build, env summary, doc pointers. |
| **Repo layout** | Root: `Cargo.toml`, `run-*.sh`, `.env.example`, `chump-brain/` (in-repo or separate clone). `src/`: Rust agent + tools. `scripts/`: setup, heartbeat, deploy, fleet, QA, roles. `web/`: PWA. `docs/`: this library. |

---

## 1. Overview and introduction

What Chump is, goals, scope, quick start.

| Document | Description |
|----------|-------------|
| [ECOSYSTEM_VISION.md](ECOSYSTEM_VISION.md) | Single vision and plan: one goal, three horizons (Now / Next / Later), build and deploy order. |
| [README.md](../README.md) | Project summary, build/run, env summary, doc index. |
| [CHUMP_PROJECT_BRIEF.md](CHUMP_PROJECT_BRIEF.md) | Current focus, conventions, quality; read with ROADMAP. |
| [SETUP_QUICK.md](SETUP_QUICK.md) | One-time setup: script, Ollama, Discord, ChumpMenu. |
| [SETUP_AND_RUN.md](SETUP_AND_RUN.md) | Run from repo root, model selection, run modes. |

---

## 2. Architecture and design

Soul, memory, resilience, tool policy, delegate, provider cascade.

| Document | Description |
|----------|-------------|
| [ARCHITECTURE.md](ARCHITECTURE.md) | Design: soul, memory, tools, delegate, tool policy, resilience. |
| [PROVIDER_CASCADE.md](PROVIDER_CASCADE.md) | Cascade: slots, priority, fallbacks, env; Mabel on Pixel (apply-mabel-badass-env, .env.mac). |
| [ROADMAP_PROVIDER_CASCADE.md](ROADMAP_PROVIDER_CASCADE.md) | Cascade roadmap and future work. |
| [RUST_INFRASTRUCTURE.md](RUST_INFRASTRUCTURE.md) | Tower, tracing, proc macro, inventory, pool, notify. |
| [TOOL_APPROVAL.md](TOOL_APPROVAL.md) | Tool approval: ask set, UX (Discord/Web), audit. |

---

## 3. Core components (implementation)

Agent loop, context assembly, tools, memory/state DBs, brain, Discord, Web/PWA, health.

| Document | Description |
|----------|-------------|
| [CHUMP_FULL_TOOLKIT.md](CHUMP_FULL_TOOLKIT.md) | Full tool list, status, build order. |
| [tools_index.md](tools_index.md) | Tool reference. |
| [CHUMP_BRAIN.md](CHUMP_BRAIN.md) | Brain: state, episodes, ego, memory_brain, directory layout. |
| [PROJECT_PLAYBOOKS.md](PROJECT_PLAYBOOKS.md) | Playbooks and project workflow. |
| [PROACTIVE_SHIPPING.md](PROACTIVE_SHIPPING.md) | Proactive shipping and heartbeat rounds. |
| [DISCORD_CONFIG.md](DISCORD_CONFIG.md) | Discord intents, env, scripts. |
| [ACP.md](ACP.md) | Agent Client Protocol adapter: V1 spec coverage, bidirectional RPC, cross-process persistence, tool-middleware wiring. |
| [ACP_V3_BACKLOG.md](ACP_V3_BACKLOG.md) | What's queued for ACP after the spec-complete landing — MCP lifecycle, vision passthrough, real-editor CI, etc. |
| [PWA_TIER2_SPEC.md](PWA_TIER2_SPEC.md) | PWA tier-2 spec. |
| [PWA_UAT.md](PWA_UAT.md) | PWA UAT. |
| [RUST_MODULE_MAP.md](RUST_MODULE_MAP.md) | Map of `src/*.rs` and `chump-tool-macro` to responsibility. |
| [WEB_API_REFERENCE.md](WEB_API_REFERENCE.md) | Axum API routes: request/response or behavior. |

---

## 4. Configuration

Environment, cascade slots, validation.

| Document | Description |
|----------|-------------|
| [OPERATIONS.md](OPERATIONS.md) | Env reference (tables), run modes, roles. |
| [.env.example](../.env.example) | Canonical env template (copy to `.env`). |
| **Code** | `src/config_validation.rs`: validation at startup. |

---

## 5. Operations and run modes

CLI/Discord/Web, model serve, heartbeats, roles, observability.

| Document | Description |
|----------|-------------|
| [OPERATIONS.md](OPERATIONS.md) | Run/serve, Discord, heartbeat, env, roles, battle QA, push/self-reboot. |
| [OLLAMA_SPEED.md](OLLAMA_SPEED.md) | Ollama tuning: context, keep_alive, model choice. |
| [STEADY_RUN.md](STEADY_RUN.md) | vLLM/Chump steady run, retries. |
| [GPU_TUNING.md](GPU_TUNING.md) | GPU/Metal tuning, OOM. |
| [HEARTBEAT_IMPROVEMENTS.md](HEARTBEAT_IMPROVEMENTS.md) | Heartbeat improvements. |
| [FLEET_ROLES.md](FLEET_ROLES.md) | Fleet roles: Chump + Mabel + Scout; implementation priority. |
| [SENTINEL_PLAYBOOK.md](SENTINEL_PLAYBOOK.md) | Sentinel playbook: objectives, sources, thresholds, actions; MAC_WEB_PORT, CHUMP_WEB_TOKEN, optional /api/dashboard check. |

---

## 6. Chump–Cursor and intent

Protocol, CLI integration, intent→action, code review, around-the-clock.

| Document | Description |
|----------|-------------|
| [AGENTS.md](../AGENTS.md) | Chump–Cursor collaboration, handoffs, what to read (repo root). |
| [CHUMP_CURSOR_PROTOCOL.md](CHUMP_CURSOR_PROTOCOL.md) | Roles, context, message types, lifecycle. |
| [CURSOR_CLI_INTEGRATION.md](CURSOR_CLI_INTEGRATION.md) | How Chump invokes Cursor; prompts, timeouts. |
| [INTENT_ACTION_PATTERNS.md](INTENT_ACTION_PATTERNS.md) | Intent→action for Discord (reduce over-asking). |
| [CURSOR_CODE_REVIEW_INTEGRATION.md](CURSOR_CODE_REVIEW_INTEGRATION.md) | Code review integration. |
| [CHUMP_CURSOR_AROUND_THE_CLOCK.md](CHUMP_CURSOR_AROUND_THE_CLOCK.md) | Around-the-clock setup. |

---

## 7. Mabel, Pixel, and fleet

Companion, Termux, deploy, A2A, performance, ADB. For Mabel cascade (faster responses), see [PROVIDER_CASCADE.md](PROVIDER_CASCADE.md) and apply-mabel-badass-env with MAC_ENV or ~/chump/.env.mac.

| Document | Description |
|----------|-------------|
| [MABEL_DOSSIER.md](MABEL_DOSSIER.md) | Mabel single-entry report: identity, architecture, config, operations, fleet role, roadmaps. |
| [MABEL_GAPS_AND_OPPORTUNITIES.md](MABEL_GAPS_AND_OPPORTUNITIES.md) | Gaps and opportunities (bot/agent only): peer_sync, mutual supervision, !status, task routing, report structure, verify round, intel topics, CHUMP_CLI_ALLOWLIST, self-heal. |
| [PROVIDER_CASCADE.md](PROVIDER_CASCADE.md) | Cascade for Mabel on Pixel: apply-mabel-badass-env, .env.mac, deploy-all-to-pixel. |
| [ANDROID_COMPANION.md](ANDROID_COMPANION.md) | Mabel on Pixel: Termux, SSH, deploy. |
| [PROJECT_PIXEL_TERMUX_COMPANION.md](PROJECT_PIXEL_TERMUX_COMPANION.md) | Pixel companion project index. |
| [MABEL_FRONTEND.md](MABEL_FRONTEND.md) | Mabel soul, tools, routing. |
| [MABEL_PERFORMANCE.md](MABEL_PERFORMANCE.md) | Mabel perf, timing, deploy-all. |
| [A2A_DISCORD.md](A2A_DISCORD.md) | Agent-to-agent: message_peer, CHUMP_A2A_PEER_USER_ID. |
| [ROADMAP_MABEL_DRIVER.md](ROADMAP_MABEL_DRIVER.md) | Mabel as driver: heartbeat, patrol, research, report. |
| [ROADMAP_MABEL_ROLES.md](ROADMAP_MABEL_ROLES.md) | Mabel takes over farm: Farmer Brown, Sentinel, Shepherd on Pixel. |
| [ROADMAP_ADB.md](ROADMAP_ADB.md) | ADB tool, Pixel/Termux. |
| [NETWORK_SWAP.md](NETWORK_SWAP.md) | After network swap: SSH config, Pixel MAC_TAILSCALE_IP. |
| [FLEET_ROLES.md](FLEET_ROLES.md) | Fleet expansion: Chump + Mabel + Scout. |
| [PROPOSAL_FLEET_ROLES.md](PROPOSAL_FLEET_ROLES.md) | Full fleet roles spec. |

---

## 8. Evaluation and QA

Battle QA, self-fix, autonomy tests.

| Document | Description |
|----------|-------------|
| [BATTLE_QA.md](BATTLE_QA.md) | 500-query QA run. |
| [BATTLE_QA_SELF_FIX.md](BATTLE_QA_SELF_FIX.md) | Self-heal workflow for battle QA. |
| [BATTLE_QA_FAILURES.md](BATTLE_QA_FAILURES.md) | Failure categories and fixes. |
| [CHUMP_AUTONOMY_TESTS.md](CHUMP_AUTONOMY_TESTS.md) | Autonomy test tiers. |

---

## 9. Roadmaps and future work

Priorities, gaps, autonomous PR, vision.

| Document | Description |
|----------|-------------|
| [ROADMAP.md](ROADMAP.md) | Single source of truth for work; unchecked items, task queue. |
| [ROADMAP_FULL.md](ROADMAP_FULL.md) | Consolidated remaining work (Priority 1–5). |
| [CLOSING_THE_GAPS.md](CLOSING_THE_GAPS.md) | Master plan Sprints 1–4; design reference. |
| [WISHLIST.md](WISHLIST.md) | Implemented + backlog. |
| [TOP_TIER_VISION.md](TOP_TIER_VISION.md) | Long-term: in-process inference, eBPF, Firecrawl, stateless tasks. |
| [AUTONOMOUS_PR_WORKFLOW.md](AUTONOMOUS_PR_WORKFLOW.md) | Task queue, PR flow, round types. |
| [SAAS_FACTORY_SETUP.md](SAAS_FACTORY_SETUP.md) | SaaS factory setup. |

---

## 10. Reference

Scripts taxonomy, env, performance, PWA, Discord troubleshooting, changelog.

| Document | Description |
|----------|-------------|
| [SCRIPTS_REFERENCE.md](SCRIPTS_REFERENCE.md) | Taxonomy: root `run-*.sh` entry points and `scripts/` (setup, heartbeat, deploy, fleet, Mabel, roles, QA, utility). |
| [OPERATIONS.md](OPERATIONS.md) | Env tables, run modes, roles (see also sections 4 and 5). |
| [PERFORMANCE.md](PERFORMANCE.md) | Performance notes. |
| [INFERENCE_MESH.md](INFERENCE_MESH.md) | Inference mesh. |
| [IOS_SHORTCUTS.md](IOS_SHORTCUTS.md) | iOS shortcuts integration. |
| [DISCORD_TROUBLESHOOTING.md](DISCORD_TROUBLESHOOTING.md) | Message Content Intent, token, reply errors. |
| [CHUMP_PLAYBOOK.md](CHUMP_PLAYBOOK.md) | Playbook and workflows. |
| [CHANGELOG.md](../CHANGELOG.md) | User-facing changes. |
