# Docs index

**Start here:** [ROADMAP.md](ROADMAP.md) (what to work on) and [CHUMP_PROJECT_BRIEF.md](CHUMP_PROJECT_BRIEF.md) (focus and conventions). Heartbeat and Cursor read these first. **Roadmap navigation hub:** [ROADMAP_MASTER.md](ROADMAP_MASTER.md) (sections linking pragmatic phases, vision, fleet, metrics, ADRs).

**Full project index and dossier:** For a complete documentation index in dossier order and a journal-style report for review, see [00-INDEX.md](00-INDEX.md) and [DOSSIER.md](DOSSIER.md).

---

## Start here (agents and humans)

| Doc | Purpose |
|-----|---------|
| [ROADMAP_MASTER.md](ROADMAP_MASTER.md) | **Master roadmap (sections):** how all roadmap docs fit together; execution vs phases vs vision vs fleet. |
| [ROADMAP.md](ROADMAP.md) | Single source of truth for work: unchecked items, task queue, fleet expansion. Read at round start. |
| [ROADMAP_PRAGMATIC.md](ROADMAP_PRAGMATIC.md) | **Full achievable backlog** in phases (A–I): reliability → autonomy → fleet → product → tools → consciousness → frontier → someday → repo hygiene. |
| [ROADMAP_REMAINING_GAPS.md](ROADMAP_REMAINING_GAPS.md) | After Phase F: what shipped vs backlog (transactional speculation, sandbox hardening). |
| [CHUMP_PROJECT_BRIEF.md](CHUMP_PROJECT_BRIEF.md) | Current focus, conventions, quality. Read with ROADMAP. |
| [AGENTS.md](../AGENTS.md) | Chump–Cursor collaboration, handoffs, what to read. |

---

## Run and operations

| Doc | Purpose |
|-----|---------|
| [SETUP_QUICK.md](SETUP_QUICK.md) | One-time setup: script, Ollama, Discord, ChumpMenu |
| [EXTERNAL_GOLDEN_PATH.md](EXTERNAL_GOLDEN_PATH.md) | **Minimal first success** for external developers (Ollama + web/CLI; no Discord/fleet) |
| [PRODUCT_CRITIQUE.md](PRODUCT_CRITIQUE.md) | Multi-angle product review matrix + **external launch gate** checklist |
| [MARKET_EVALUATION.md](MARKET_EVALUATION.md) | **ICP, competitive matrix, north stars, memo, interview kit** — market truth vs consumer/IDE bots |
| [DEFENSE_MARKET_RESEARCH.md](DEFENSE_MARKET_RESEARCH.md) | **DoD / defense industrial base:** SBIR status check, wedge use case, compliance architecture, partner map for Chump-style agents |
| [DEFENSE_PILOT_EXECUTION.md](DEFENSE_PILOT_EXECUTION.md) | **Execute the wedge:** SAM.gov, pilot charter template, outreach copy, discovery script, demo MVP scope |
| [FEDERAL_OPPORTUNITIES_PIPELINE.md](FEDERAL_OPPORTUNITIES_PIPELINE.md) | **Live federal market:** SAM Contract Opportunities (UI + API), USAspending intel, DIU, Colorado/SLED, weekly scan rhythm |
| [WEDGE_PILOT_METRICS.md](WEDGE_PILOT_METRICS.md) | **Pilot N3/N4:** SQL + API + JSONL recipes over `chump_memory.db` |
| [scripts/export-pilot-summary.sh](../scripts/export-pilot-summary.sh) | **`GET /api/pilot-summary`** JSON for pilot weekly check-in |
| [WEDGE_H1_GOLDEN_EXTENSION.md](WEDGE_H1_GOLDEN_EXTENSION.md) | After golden path: PWA/API task + optional `autonomy_once`; `scripts/wedge-h1-smoke.sh` |
| [INTENT_CALIBRATION.md](INTENT_CALIBRATION.md) | Labeled intent→action eval set + scoring procedure |
| [TRUST_SPECULATIVE_ROLLBACK.md](TRUST_SPECULATIVE_ROLLBACK.md) | What speculative rollback does **not** undo (diagram + ADR link) |
| [PWA_WEDGE_PATH.md](PWA_WEDGE_PATH.md) | PWA-first H1 wedge audit (Discord optional) |
| [ONBOARDING_FRICTION_LOG.md](ONBOARDING_FRICTION_LOG.md) | Timed cold-clone onboarding template + friction notes |
| [STORAGE_AND_ARCHIVE.md](STORAGE_AND_ARCHIVE.md) | Disk use, cleanup script, embed cache, `git gc`, quarterly export |
| [SETUP_AND_RUN.md](SETUP_AND_RUN.md) | Run from repo root, model selection |
| [INFERENCE_PROFILES.md](INFERENCE_PROFILES.md) | **Canonical** vLLM-MLX (8000) vs Ollama (11434), env, startup order, switching |
| [INFERENCE_STABILITY.md](INFERENCE_STABILITY.md) | OOM/crash-loop triage, Farmer Brown, links to GPU tuning and steady run |
| [OPERATIONS.md](OPERATIONS.md) | Run/serve, Discord, heartbeat, env, roles, battle QA, push/self-reboot |
| [ROAD_TEST_VALIDATION.md](ROAD_TEST_VALIDATION.md) | Local road-test: smoke test, consciousness exercise, mini A/B, `/health`, battle QA smoke |
| [CAPABILITY_CHECKLIST.md](CAPABILITY_CHECKLIST.md) | **Layered testing ladder:** CI, golden path, Battle QA triage, consciousness scripts, 10 manual scenarios |
| [PRODUCT_ROADMAP_CHIEF_OF_STAFF.md](PRODUCT_ROADMAP_CHIEF_OF_STAFF.md) | **COS product roadmap:** 60 user stories, waves (instrument → loop → discovery → new products), weekly DB snapshot script |
| [COS_DECISION_LOG.md](COS_DECISION_LOG.md) | **COS decisions + interrupt tags:** `cos/decisions/` under brain, template, `CHUMP_INTERRUPT_NOTIFY_POLICY` allowlist for `notify` during heartbeat |
| [PROBLEM_VALIDATION_CHECKLIST.md](PROBLEM_VALIDATION_CHECKLIST.md) | **Wave 4:** validate a problem before a new repo; episode stub; links to scaffold + portfolio |
| [templates/cos-portfolio.md](templates/cos-portfolio.md) | **Portfolio map template** for `chump-brain/cos/portfolio.md` (experiment / active / sunset) |
| [PROVIDER_CASCADE.md](PROVIDER_CASCADE.md) | Cascade slots (Groq, Cerebras, etc.), keys, Mabel on Pixel |
| [DISCORD_TROUBLESHOOTING.md](DISCORD_TROUBLESHOOTING.md) | Message Content Intent, token, reply errors |
| [DISCORD_CONFIG.md](DISCORD_CONFIG.md) | Discord intents, env, scripts |
| [OLLAMA_SPEED.md](OLLAMA_SPEED.md) | Ollama tuning: context, keep_alive, model choice |
| [STEADY_RUN.md](STEADY_RUN.md) | vLLM/Chump steady run, retries |
| [GPU_TUNING.md](GPU_TUNING.md) | GPU/Metal tuning, OOM |
| [STORAGE_AND_ARCHIVE.md](STORAGE_AND_ARCHIVE.md) | Disk use (`target/`, caches), safe cleanup, archiving `sessions/` / `logs/` without losing project context |

---

## Roadmaps and plans

| Doc | Purpose |
|-----|---------|
| [ROADMAP_MASTER.md](ROADMAP_MASTER.md) | **Navigation hub:** sections for execution (ROADMAP), phases A–I (pragmatic), vision, consciousness/metrics/ADRs, fleet, sprints. |
| [CHUMP_TO_COMPLEX.md](CHUMP_TO_COMPLEX.md) | **Master vision:** the chump → complex transition. Maps theory (FEP, IIT, GWT, Thermodynamic AI, Causal Reasoning) to shipped code, near-term hardening, medium-term core builds, and frontier research. Supersedes TOP_TIER_VISION.md. |
| [ECOSYSTEM_VISION.md](ECOSYSTEM_VISION.md) | **Ecosystem plan:** one goal, three horizons (Now / Next / Later), what to build and deploy in order. Read first for alignment. |
| [ROADMAP_FULL.md](ROADMAP_FULL.md) | Consolidated remaining work (Priority 1–5); historical detail. Prefer [ROADMAP_PRAGMATIC.md](ROADMAP_PRAGMATIC.md) for ordering. Use with ROADMAP.md. |
| [ROADMAP_CLAUDE_UPGRADE.md](ROADMAP_CLAUDE_UPGRADE.md) | **Aspirational "Claude tier":** semantic context, smart edits, task-plan autonomy, reasoning tags, delegate preprocessing — phased checklist aligned to `src/` modules. |
| [PRAGMATIC_EXECUTION_CHECKLIST.md](PRAGMATIC_EXECUTION_CHECKLIST.md) | **Execution order:** local stability → telemetry → autonomy → reasoning → edits → swarm toggle (Phase 6 swarm items implemented; Phases 1–5 open). |
| [CLAUDE_COWORK_UPGRADE_PLAN.md](CLAUDE_COWORK_UPGRADE_PLAN.md) | **Cowork tier plan:** phase-gated M4-first upgrade (read first per session); Phases 1–5 spec, Phase 6 partially implemented + scaffold only until authorized. |
| [TAURI_FRONTEND_PLAN.md](TAURI_FRONTEND_PLAN.md) | **Cowork UI:** Tauri + PWA plan (execution sidebar, thinking mask, approval dashboard); Phases 1–3; repo notes on `lib` split vs HTTP bridge. |
| [FLEET_ROLES.md](FLEET_ROLES.md) | Fleet expansion: Chump + Mabel + Scout; implementation priority. Full spec: [PROPOSAL_FLEET_ROLES.md](PROPOSAL_FLEET_ROLES.md) |
| [CLOSING_THE_GAPS.md](CLOSING_THE_GAPS.md) | Master plan Sprints 1–4; status at top; design reference |
| [ROADMAP_MABEL_DRIVER.md](ROADMAP_MABEL_DRIVER.md) | Mabel as driver: heartbeat, patrol, research, report, intel, verify, peer_sync |
| [ROADMAP_MABEL_ROLES.md](ROADMAP_MABEL_ROLES.md) | Mabel takes over farm: Farmer Brown, Sentinel, Shepherd on Pixel |
| [ROADMAP_ADB.md](ROADMAP_ADB.md) | ADB tool, Pixel/Termux |
| [AUTONOMOUS_PR_WORKFLOW.md](AUTONOMOUS_PR_WORKFLOW.md) | Task queue, PR flow, round types |
| [TOP_TIER_VISION.md](TOP_TIER_VISION.md) | Long-term: in-process inference, eBPF, Firecrawl, stateless tasks, JIT WASM |
| [RUST_INFRASTRUCTURE.md](RUST_INFRASTRUCTURE.md) | Tower, tracing, proc macro, inventory, typestate, pool, notify — status and design |

---

## Brain, tools, QA

| Doc | Purpose |
|-----|---------|
| [CHUMP_BRAIN.md](CHUMP_BRAIN.md) | State, episodes, ego, memory_brain, shared repo, directory layout (research/watch/capture/projects/reports) |
| [WISHLIST.md](WISHLIST.md) | Implemented + backlog |
| [CHUMP_FULL_TOOLKIT.md](CHUMP_FULL_TOOLKIT.md) | Full tool list, status, build order |
| [tools_index.md](tools_index.md) | Tool reference |
| [BATTLE_QA.md](BATTLE_QA.md) | 500-query QA; self-heal: [BATTLE_QA_SELF_FIX.md](BATTLE_QA_SELF_FIX.md) |
| [BATTLE_QA_FAILURES.md](BATTLE_QA_FAILURES.md) | Failure categories and fixes |

---

## Chump–Cursor and intent

| Doc | Purpose |
|-----|---------|
| [CHUMP_CURSOR_PROTOCOL.md](CHUMP_CURSOR_PROTOCOL.md) | Roles, context, message types, lifecycle |
| [CURSOR_CLI_INTEGRATION.md](CURSOR_CLI_INTEGRATION.md) | How Chump invokes Cursor; prompts, timeouts |
| [INTENT_ACTION_PATTERNS.md](INTENT_ACTION_PATTERNS.md) | Intent→action for Discord (reduce over-asking) |
| [CONTINUAL_LEARNING.md](CONTINUAL_LEARNING.md) | **Cursor continual-learning:** `agents-memory-updater`, transcript index (`.cursor/hooks/state/`), merging into `AGENTS.md` learned sections |

---

## Mabel and Pixel

**Mabel cascade for speed:** Enable cascade on Pixel via `apply-mabel-badass-env.sh` with MAC_ENV or ~/chump/.env.mac (or after deploy-all-to-pixel). See [PROVIDER_CASCADE.md](PROVIDER_CASCADE.md).

| Doc | Purpose |
|-----|---------|
| [ANDROID_COMPANION.md](ANDROID_COMPANION.md) | Mabel on Pixel: Termux, SSH, deploy |
| [PROJECT_PIXEL_TERMUX_COMPANION.md](PROJECT_PIXEL_TERMUX_COMPANION.md) | Pixel companion project index |
| [MABEL_PERFORMANCE.md](MABEL_PERFORMANCE.md) | Mabel perf, timing, deploy-all |
| [MABEL_FRONTEND.md](MABEL_FRONTEND.md) | Mabel soul, tools, routing |
| [A2A_DISCORD.md](A2A_DISCORD.md) | Agent-to-agent: message_peer, CHUMP_A2A_PEER_USER_ID |
| [NETWORK_SWAP.md](NETWORK_SWAP.md) | After network swap: SSH config, Pixel MAC_TAILSCALE_IP |

---

## Reference

| Doc | Purpose |
|-----|---------|
| [CHUMP_RESEARCH_BRIEF.md](CHUMP_RESEARCH_BRIEF.md) | **External review:** what Chump is, how a turn works, consciousness-inspired layer as engineering + non-claims + open questions |
| [ARCHITECTURE.md](ARCHITECTURE.md) | Design, tools, soul, brain |
| [OPERATIONS.md](OPERATIONS.md) | Env reference (see Run and operations) |
| [SCRIPTS_REFERENCE.md](SCRIPTS_REFERENCE.md) | Taxonomy of run scripts and scripts/ (setup, heartbeat, deploy, Mabel, roles) |
| [CHUMP_PLAYBOOK.md](CHUMP_PLAYBOOK.md) | Playbook and workflows |
| [CHUMP_AUTONOMY_TESTS.md](CHUMP_AUTONOMY_TESTS.md) | Autonomy test tiers |
| [PERFORMANCE.md](PERFORMANCE.md) | Performance notes |
| [CURSOR_CODE_REVIEW_INTEGRATION.md](CURSOR_CODE_REVIEW_INTEGRATION.md) | Code review integration |
| [CHUMP_CURSOR_AROUND_THE_CLOCK.md](CHUMP_CURSOR_AROUND_THE_CLOCK.md) | Around-the-clock setup |
| [HEARTBEAT_IMPROVEMENTS.md](HEARTBEAT_IMPROVEMENTS.md) | Heartbeat improvements |
| [INFERENCE_MESH.md](INFERENCE_MESH.md) | Inference mesh |
| [ADR-001-transactional-tool-speculation.md](ADR-001-transactional-tool-speculation.md) | Future: true transactional tool speculation vs today’s memory-only rollback |
