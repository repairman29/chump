# Chump: project dossier for review

This document is a single-entry report for external review and critique. It follows a technical-report structure; each section gives a short narrative and pointers into the documentation library. Full detail lives in the linked docs. The master index of all documentation is [00-INDEX.md](00-INDEX.md).

---

## Abstract

Chump is a local AI agent implemented in Rust that talks to OpenAI-compatible endpoints (e.g. Ollama, vLLM-MLX, or a cloud cascade). It acts as one orchestrator with optional delegate workers: Discord bot, CLI (one-shot or REPL), and a PWA for chat and tasks. The system provides tools for memory (SQLite FTS5 with optional semantic recall), repo read/write, GitHub, git, tasks, schedule, and self-audit (e.g. diff_review, battle_QA). A provider cascade routes requests across multiple model slots with priority and fallback. State and continuity live in a "brain" (wiki under CHUMP_BRAIN_PATH) and SQLite (episodes, tasks, schedule). Chump is designed for 24/7 operation with heartbeats (ship, self-improve, learn, Mabel), fleet roles (Farmer Brown, Sentinel, etc.), and optional Android companion (Mabel) on a Pixel device. Observability includes a PWA Dashboard (ship status, current step, recent episodes) and a Sentinel playbook for alerts and optional web checks. This dossier documents architecture, implementation, configuration, operations, evaluation, and roadmaps.

---

## 1. Introduction and overview

Chump aims to be a single local agent that can run from a Mac (and optionally an Android companion), use local or cloud inference, and support both human interaction (Discord, PWA, CLI) and autonomous rounds (heartbeats, scheduled work). Goals include implementation quality (shipping working code and docs), speed (faster rounds, less friction), and bot capabilities—especially inferring user intent in Discord and acting without over-asking.

- See [README.md](../README.md) for project summary, build/run, and env summary.
- See [CHUMP_PROJECT_BRIEF.md](CHUMP_PROJECT_BRIEF.md) for current focus and conventions.
- See [SETUP_QUICK.md](SETUP_QUICK.md) for one-time setup.
- See [SETUP_AND_RUN.md](SETUP_AND_RUN.md) for run modes and model selection.

---

## 2. Architecture and design

The design centers on a "soul" (system prompt and personality), durable memory and state (SQLite: memory, episodes, tasks, schedule), and a rich tool set with policy (allow/deny/ask) and optional approval UX. A delegate tool can offload summarize/extract/classify/validate to a worker. The provider cascade allows multiple model slots (local and cloud) with priority and fallback. Resilience includes retries, circuit breakers, and kill switches; tool policy supports an "ask" set with heuristic risk and audit logging.

- See [ARCHITECTURE.md](ARCHITECTURE.md) for soul, memory, tools, delegate, and resilience.
- See [PROVIDER_CASCADE.md](PROVIDER_CASCADE.md) for cascade slots and fallbacks.
- See [ROADMAP_PROVIDER_CASCADE.md](ROADMAP_PROVIDER_CASCADE.md) for cascade roadmap.
- See [RUST_INFRASTRUCTURE.md](RUST_INFRASTRUCTURE.md) for Tower, tracing, proc macro, inventory, pool.
- See [TOOL_APPROVAL.md](TOOL_APPROVAL.md) for tool approval flow and audit.

---

## 3. Core components and implementation

The agent loop drives turns, context assembly, and tool dispatch. Context is assembled from system prompt, round-filtered brain content (portfolio, playbook), and message history; when the history exceeds a token threshold, oldest messages are summarized via delegate. Tools are registered via an inventory and routed by name; middleware and policy apply allowlist/blocklist, caps, and approval. Memory and state use SQLite (memory_db, state_db, episode_db, task_db, schedule_db). The brain is a wiki under CHUMP_BRAIN_PATH with memory_brain tool and project playbooks. Discord and web servers provide the main user-facing surfaces; a health server exposes status for ChumpMenu and scripts. The PWA includes a **Dashboard** tab that shows ship heartbeat status, the current chassis step ("what we're doing"), and recent episodes; data comes from `GET /api/dashboard` (see WEB_API_REFERENCE).

- See [CHUMP_FULL_TOOLKIT.md](CHUMP_FULL_TOOLKIT.md) and [tools_index.md](tools_index.md) for the full tool set.
- See [CHUMP_BRAIN.md](CHUMP_BRAIN.md), [PROJECT_PLAYBOOKS.md](PROJECT_PLAYBOOKS.md), and [PROACTIVE_SHIPPING.md](PROACTIVE_SHIPPING.md) for brain and playbooks.
- See [DISCORD_CONFIG.md](DISCORD_CONFIG.md), [PWA_TIER2_SPEC.md](PWA_TIER2_SPEC.md), and [PWA_UAT.md](PWA_UAT.md) for Discord and PWA.
- See [RUST_MODULE_MAP.md](RUST_MODULE_MAP.md) for the map of Rust modules.
- See [WEB_API_REFERENCE.md](WEB_API_REFERENCE.md) for the web API routes.

---

## 4. Configuration

Configuration is environment-based: copy `.env.example` to `.env` and set secrets and options. Key areas include OpenAI-compatible base URL and model, Discord token, CHUMP_REPO/CHUMP_HOME, cascade slot env vars (base, key, model, RPM/RPD), brain path, tool-approval ask set, and optional executive mode. Config is validated at startup.

- See [OPERATIONS.md](OPERATIONS.md) for env reference tables.
- See [.env.example](../.env.example) for the canonical template.
- Validation logic: `src/config_validation.rs`.

---

## 5. Operations and run modes

Chump runs as CLI (single message or REPL), Discord bot, or web server. Run scripts (e.g. run-discord.sh, run-local.sh, run-web.sh) set CHUMP_HOME/CHUMP_REPO and source .env before invoking the binary. Model serving is via Ollama or vLLM-MLX; tuning and steady-run behavior are documented. Heartbeats (ship, self-improve, learn, Mabel, cursor-improve, shepherd) run on schedules; fleet roles (Farmer Brown, Sentinel, memory-keeper, oven-tender, hourly-update) are installed via launchd. Sentinel is documented in a playbook (objectives, thresholds, optional Mac Web API check for ship/dashboard visibility). Observability includes the health endpoint, the PWA Dashboard, and logs (chump.log, discord.log, heartbeat logs).

- See [OPERATIONS.md](OPERATIONS.md) for run modes, heartbeats, and roles.
- See [OLLAMA_SPEED.md](OLLAMA_SPEED.md), [STEADY_RUN.md](STEADY_RUN.md), and [GPU_TUNING.md](GPU_TUNING.md) for model tuning.
- See [HEARTBEAT_IMPROVEMENTS.md](HEARTBEAT_IMPROVEMENTS.md) and [FLEET_ROLES.md](FLEET_ROLES.md) for heartbeats and roles.
- See [SENTINEL_PLAYBOOK.md](SENTINEL_PLAYBOOK.md) for the Sentinel playbook.

---

## 6. Chump–Cursor and intent

Chump and Cursor collaborate via a protocol that defines roles, context, message types, and lifecycle. Chump can invoke Cursor (e.g. for code changes) with documented prompts and timeouts. Intent–action patterns reduce over-asking in Discord by inferring user intent and taking action when clear. Code review integration and around-the-clock setup are documented.

- See [AGENTS.md](../AGENTS.md) for Chump–Cursor handoffs and what to read (repo root).
- See [CHUMP_CURSOR_PROTOCOL.md](CHUMP_CURSOR_PROTOCOL.md) for the protocol.
- See [CURSOR_CLI_INTEGRATION.md](CURSOR_CLI_INTEGRATION.md) for how Chump invokes Cursor.
- See [INTENT_ACTION_PATTERNS.md](INTENT_ACTION_PATTERNS.md) for intent→action in Discord.
- See [CURSOR_CODE_REVIEW_INTEGRATION.md](CURSOR_CODE_REVIEW_INTEGRATION.md) and [CHUMP_CURSOR_AROUND_THE_CLOCK.md](CHUMP_CURSOR_AROUND_THE_CLOCK.md) for code review and 24/7 setup.

---

## 7. Mabel, Pixel, and fleet

Mabel is the Android companion running on a Pixel device (e.g. Termux). She can run heartbeats, patrol, research, and report; roadmaps describe her taking over farm roles (Farmer Brown, Sentinel, Shepherd) on the device. When MAC_WEB_PORT and CHUMP_WEB_TOKEN are set, Mabel can call the Mac `GET /api/dashboard` for ship status and cascade visibility (see ROADMAP_MABEL_ROLES). Deployment is via deploy scripts (deploy-mabel-to-pixel.sh, deploy-fleet.sh). Agent-to-agent messaging (message_peer) uses CHUMP_A2A_PEER_USER_ID. ADB and network-swap procedures are documented.

- See [MABEL_DOSSIER.md](MABEL_DOSSIER.md) for the Mabel single-entry report (identity, architecture, config, operations, fleet role).
- See [ANDROID_COMPANION.md](ANDROID_COMPANION.md) and [PROJECT_PIXEL_TERMUX_COMPANION.md](PROJECT_PIXEL_TERMUX_COMPANION.md) for Mabel on Pixel.
- See [MABEL_FRONTEND.md](MABEL_FRONTEND.md) and [MABEL_PERFORMANCE.md](MABEL_PERFORMANCE.md) for Mabel behavior and perf.
- See [A2A_DISCORD.md](A2A_DISCORD.md), [ROADMAP_MABEL_DRIVER.md](ROADMAP_MABEL_DRIVER.md), [ROADMAP_MABEL_ROLES.md](ROADMAP_MABEL_ROLES.md), [ROADMAP_ADB.md](ROADMAP_ADB.md), [NETWORK_SWAP.md](NETWORK_SWAP.md).
- See [FLEET_ROLES.md](FLEET_ROLES.md) and [PROPOSAL_FLEET_ROLES.md](PROPOSAL_FLEET_ROLES.md) for fleet expansion.

---

## 8. Evaluation and QA

Battle QA runs a large query set (e.g. 500 queries) to stress the agent; a self-heal workflow allows the system to fix failures and re-run. Failure categories and fixes are documented. Autonomy tests are tiered and used to validate autonomous behavior.

- See [BATTLE_QA.md](BATTLE_QA.md), [BATTLE_QA_SELF_FIX.md](BATTLE_QA_SELF_FIX.md), and [BATTLE_QA_FAILURES.md](BATTLE_QA_FAILURES.md).
- See [CHUMP_AUTONOMY_TESTS.md](CHUMP_AUTONOMY_TESTS.md) for autonomy test tiers.

---

## 9. Roadmaps and future work

The roadmap is the single source of truth for what to work on (unchecked items, task queue, fleet expansion). For a single vision and the order to build and deploy the ecosystem (three horizons: Now, Next, Later), see [ECOSYSTEM_VISION.md](ECOSYSTEM_VISION.md). Consolidated roadmaps and closing-the-gaps plans define priorities. Future work includes autonomous PR workflow, multi-repo tools, quality guards, context-window and ops maturity, and long-term vision (in-process inference, eBPF, Firecrawl, stateless tasks, JIT WASM).

- See [ECOSYSTEM_VISION.md](ECOSYSTEM_VISION.md) for the one goal and build/deploy plan.
- See [ROADMAP.md](ROADMAP.md) and [ROADMAP_FULL.md](ROADMAP_FULL.md).
- See [CLOSING_THE_GAPS.md](CLOSING_THE_GAPS.md), [WISHLIST.md](WISHLIST.md), [TOP_TIER_VISION.md](TOP_TIER_VISION.md).
- See [AUTONOMOUS_PR_WORKFLOW.md](AUTONOMOUS_PR_WORKFLOW.md) and [SAAS_FACTORY_SETUP.md](SAAS_FACTORY_SETUP.md).

---

## 10. Reference

Scripts are grouped by purpose (setup, run/serve, heartbeat, fleet/deploy, Mabel/Pixel, roles, QA, utility). Environment reference and performance notes are in OPERATIONS and PERFORMANCE. Discord troubleshooting, PWA, and iOS shortcuts are documented. The changelog records user-facing changes.

- See [SCRIPTS_REFERENCE.md](SCRIPTS_REFERENCE.md) for the scripts taxonomy.
- See [OPERATIONS.md](OPERATIONS.md), [PERFORMANCE.md](PERFORMANCE.md), [INFERENCE_MESH.md](INFERENCE_MESH.md).
- See [IOS_SHORTCUTS.md](IOS_SHORTCUTS.md), [DISCORD_TROUBLESHOOTING.md](DISCORD_TROUBLESHOOTING.md), [CHUMP_PLAYBOOK.md](CHUMP_PLAYBOOK.md).
- See [CHANGELOG.md](../CHANGELOG.md) for release history.

---

## References

- **Documentation index:** [00-INDEX.md](00-INDEX.md) — master list of all docs in dossier order.
- **Day-to-day doc index:** [README.md](README.md) — run, roadmaps, brain, Mabel, reference.
