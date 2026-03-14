# Docs index

**Start here:** [ROADMAP.md](ROADMAP.md) (what to work on) and [CHUMP_PROJECT_BRIEF.md](CHUMP_PROJECT_BRIEF.md) (focus and conventions). Heartbeat and Cursor read these first.

---

## Start here (agents and humans)

| Doc | Purpose |
|-----|---------|
| [ROADMAP.md](ROADMAP.md) | Single source of truth for work: unchecked items, task queue, fleet expansion. Read at round start. |
| [CHUMP_PROJECT_BRIEF.md](CHUMP_PROJECT_BRIEF.md) | Current focus, conventions, quality. Read with ROADMAP. |
| [AGENTS.md](../AGENTS.md) | Chump–Cursor collaboration, handoffs, what to read. |

---

## Run and operations

| Doc | Purpose |
|-----|---------|
| [SETUP_QUICK.md](SETUP_QUICK.md) | One-time setup: script, Ollama, Discord, ChumpMenu |
| [SETUP_AND_RUN.md](SETUP_AND_RUN.md) | Run from repo root, model selection |
| [OPERATIONS.md](OPERATIONS.md) | Run/serve, Discord, heartbeat, env, roles, battle QA, push/self-reboot |
| [DISCORD_TROUBLESHOOTING.md](DISCORD_TROUBLESHOOTING.md) | Message Content Intent, token, reply errors |
| [DISCORD_CONFIG.md](DISCORD_CONFIG.md) | Discord intents, env, scripts |
| [OLLAMA_SPEED.md](OLLAMA_SPEED.md) | Ollama tuning: context, keep_alive, model choice |
| [STEADY_RUN.md](STEADY_RUN.md) | vLLM/Chump steady run, retries |
| [GPU_TUNING.md](GPU_TUNING.md) | GPU/Metal tuning, OOM |

---

## Roadmaps and plans

| Doc | Purpose |
|-----|---------|
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

---

## Mabel and Pixel

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
| [ARCHITECTURE.md](ARCHITECTURE.md) | Design, tools, soul, brain |
| [OPERATIONS.md](OPERATIONS.md) | Env reference (see Run and operations) |
| [CHUMP_PLAYBOOK.md](CHUMP_PLAYBOOK.md) | Playbook and workflows |
| [CHUMP_AUTONOMY_TESTS.md](CHUMP_AUTONOMY_TESTS.md) | Autonomy test tiers |
| [PERFORMANCE.md](PERFORMANCE.md) | Performance notes |
| [CURSOR_CODE_REVIEW_INTEGRATION.md](CURSOR_CODE_REVIEW_INTEGRATION.md) | Code review integration |
| [CHUMP_CURSOR_AROUND_THE_CLOCK.md](CHUMP_CURSOR_AROUND_THE_CLOCK.md) | Around-the-clock setup |
| [HEARTBEAT_IMPROVEMENTS.md](HEARTBEAT_IMPROVEMENTS.md) | Heartbeat improvements |
| [INFERENCE_MESH.md](INFERENCE_MESH.md) | Inference mesh |
