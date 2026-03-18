# Mabel: project dossier for review

This document is a single-entry report for external review and critique. It follows the same technical-report structure as the Chump dossier. Each section gives a short narrative and pointers into the documentation library. Full detail lives in the linked docs.

---

## Abstract

Mabel is the Android companion instance of the Chump agent: the same Rust binary and tool set, running on a Pixel 8 Pro (or similar aarch64 device) under Termux, with her **own Discord Application and token**. She uses llama.cpp + Vulkan for local inference (llama-server on port 8000) instead of vLLM-MLX. She acts as a pocket companion (Discord bot, optional CLI), runs autonomous heartbeat rounds (patrol, research, report, intel, verify, peer_sync), and can monitor and repair the Mac stack remotely via SSH and optional Web API. She shares the Chump "brain" (wiki) with Chump for sync and intel. This dossier documents Mabel's identity, architecture, configuration, operations, fleet role, and roadmaps.

---

## 1. Introduction and overview

Mabel exists to give the fleet a second, independent node: always-on on the Pixel, connected over Tailscale, with her own model and Discord identity. She can answer DMs, run proactive rounds, monitor the Mac (Farmer Brown / Sentinel style), file unified reports, and coordinate with Chump via `message_peer`. Goals include reliability (Termux + wake-lock, self-heal), clear identity (Mabel soul, CHUMP_MABEL=1), and fleet symbiosis (mutual supervision, shared brain, deploy from Mac).

- See [README.md](../README.md) for project summary and build.
- See [ANDROID_COMPANION.md](ANDROID_COMPANION.md) for "Get Mabel online" checklist and architecture.
- See [MABEL_FRONTEND.md](MABEL_FRONTEND.md) for naming, soul, and chat options.

---

## 2. Identity and differentiation

**Mabel vs Chump:** Same binary, different config and Discord app. On the Pixel, `~/chump/.env` must use **Mabel's** bot token (Discord Developer Portal app named "Mabel"). On the Mac, Chump uses his own app and token. Never use Chump's token on the Pixel. Mabel's Discord application ID: **1478435625266053333**; Chump's: **1480406053849010369**. When a DM must appear from Mabel, the script must run on the Pixel with Mabel's token; on the Mac the message shows as Chump.

**Soul:** Set `CHUMP_SYSTEM_PROMPT` in `~/chump/.env` on the Pixel to define Mabel's personality (e.g. pocket companion, confident, no corporate fluff). Set **CHUMP_MABEL=1** so the runtime uses the short "Tools (companion)" list. Reply format: final answer only; no `</think>` or `think>` blocks in external messaging.

- See [MABEL_FRONTEND.md](MABEL_FRONTEND.md) for naming and soul.
- See [MABEL_PERFORMANCE.md](MABEL_PERFORMANCE.md) § "Max Mabel" for env do/don't set.

---

## 3. Architecture and design

On the Pixel, Mabel runs inside Termux: chump (Discord bot) talks to **llama-server** (llama.cpp + Vulkan, OpenAI-compatible API on port 8000). SQLite (memory, episodes, tasks) and logs live under `~/chump`. No macOS-specific code in the agent path; vLLM-MLX and ChumpMenu are Mac-only and replaced on the Pixel by llama-server and Termux. For hybrid inference, research/report rounds can use the Mac's larger model via `MABEL_HEAVY_MODEL_BASE` while patrol/intel/verify/peer_sync stay on the local model.

- See [ANDROID_COMPANION.md](ANDROID_COMPANION.md) for the Pixel architecture diagram and stack.
- See [MABEL_PERFORMANCE.md](MABEL_PERFORMANCE.md) for model, context, Vulkan tuning and "Max Mabel."

---

## 4. Core components and implementation

Same agent loop and tool inventory as Chump; tool policy (allowlist/blocklist, run_cli allowlist) applies. Mabel uses memory, tasks, schedule, ego, episode, memory_brain, read_url, web_search (when TAVILY set), notify, message_peer, and file tools under `~/chump`. Optional: delegate worker, GitHub tools (if GITHUB_TOKEN/CHUMP_GITHUB_REPOS set). Patrol round runs **mabel-farmer.sh** (diagnose + optional fix of Mac stack and local llama-server); heartbeat script drives round types and shared-brain pull/push.

- See [CHUMP_FULL_TOOLKIT.md](CHUMP_FULL_TOOLKIT.md) and [tools_index.md](tools_index.md) for the full tool set.
- See [ANDROID_COMPANION.md](ANDROID_COMPANION.md) for Mabel heartbeat and shared brain.
- See [ROADMAP_MABEL_DRIVER.md](ROADMAP_MABEL_DRIVER.md) for round types and prompts.

---

## 5. Configuration

Configuration is environment-based in `~/chump/.env` on the Pixel. Key: **DISCORD_TOKEN** (Mabel's token only), **OPENAI_API_BASE** (e.g. `http://localhost:8000/v1`), **OPENAI_API_KEY** / **OPENAI_MODEL**, **CHUMP_SYSTEM_PROMPT**, **CHUMP_MABEL=1**. Optional: **CHUMP_CTX_SIZE**, **CHUMP_GPU_LAYERS**, **CHUMP_MODEL** (llama-server model path), cascade vars (**CHUMP_CASCADE_ENABLED=1**, **CHUMP_PROVIDER_N_***) for cloud fallback, **MABEL_HEAVY_MODEL_BASE** for hybrid inference, **CHUMP_CLI_ALLOWLIST** for run_cli safety. For mutual supervision: **MAC_TAILSCALE_IP**, **MAC_SSH_PORT**, **MAC_CHUMP_HOME**, **MAC_USER**; Mac side: **PIXEL_SSH_HOST**, **PIXEL_SSH_PORT**. Do not set CHUMP_REPO/CHUMP_HOME, CHUMP_WARM_SERVERS, CHUMP_CURSOR_CLI, or CHUMP_PROJECT_MODE on the Pixel.

- See [OPERATIONS.md](OPERATIONS.md) for env tables and Mabel cascade setup.
- See [MABEL_PERFORMANCE.md](MABEL_PERFORMANCE.md) for tunables and "Max Mabel."
- See [.env.example](../.env.example) for the canonical template.

---

## 6. Operations and run modes

**Start Mabel:** In Termux, `cd ~/chump && ./start-companion.sh` (starts llama-server then Discord bot). Use nohup/tmux or Termux:Boot for 24/7. **Deploy from Mac:** `./scripts/deploy-all-to-pixel.sh [termux]` (build, push binary and scripts, apply Mabel env, restart); binary-only: `./scripts/deploy-mabel-to-pixel.sh [termux]`. **Heartbeat:** `scripts/heartbeat-mabel.sh` on the Pixel; rounds: patrol (mabel-farmer + agent), research, report, intel, verify, peer_sync. Start/stop from Mac via ChumpMenu ("Start Mabel heartbeat" / "Stop Mabel heartbeat") or SSH. Log: `~/chump/logs/heartbeat-mabel.log`. **Mutual supervision:** Mac restarts Mabel's heartbeat when stale; Mabel restarts Chump's heartbeat when stale (see OPERATIONS.md § "Mutual supervision"). **Restart Mabel when Pixel is on USB:** `./scripts/restart-mabel-bot-on-pixel.sh` (ADB forward 8022 for SSH).

- See [ANDROID_COMPANION.md](ANDROID_COMPANION.md) for get-online checklist and Mabel heartbeat.
- See [OPERATIONS.md](OPERATIONS.md) for Farmer Brown + Mabel, mutual supervision, hybrid inference, Mabel cascade.
- See [MABEL_PERFORMANCE.md](MABEL_PERFORMANCE.md) for deploy, restart, and troubleshooting.

---

## 7. Fleet role: patrol, Sentinel, report, and Chump

Mabel's **patrol** round runs **mabel-farmer.sh**: diagnoses Mac stack (Tailscale, SSH, Ollama, model port, embed, Discord process, optional health endpoint) and local llama-server; can SSH to Mac and run **farmer-brown.sh** to repair; on repeated failure can DM the user via Mabel's Discord. She can run **report** (unified fleet report), **intel** (web research, memory_brain), **verify** (QA of Chump's last change), and **peer_sync** (message_peer to Chump). When **MAC_WEB_PORT** and **CHUMP_WEB_TOKEN** are set, Mabel can call the Mac `GET /api/dashboard` for ship status. Agent-to-agent messaging uses **CHUMP_A2A_PEER_USER_ID**. Shared brain: clone at `~/chump/chump-brain`; heartbeat pulls at round start and pushes at round end.

- See [ROADMAP_MABEL_ROLES.md](ROADMAP_MABEL_ROLES.md) for Mabel-as-farm-monitor and role migration.
- See [ROADMAP_MABEL_DRIVER.md](ROADMAP_MABEL_DRIVER.md) for heartbeat rounds and coordination.
- See [FLEET_ROLES.md](FLEET_ROLES.md) and [A2A_DISCORD.md](A2A_DISCORD.md) for fleet and A2A.

---

## 8. Evaluation and QA

Mabel's **verify** round can independently check Chump's last code change (e.g. run tests on Mac via SSH). Battle QA and autonomy test tiers apply to the same binary; device-specific checks (latency, OOM, Termux kill) are documented in Mabel performance and Android companion docs.

- See [MABEL_PERFORMANCE.md](MABEL_PERFORMANCE.md) for diagnosing delays and capturing timing.
- See [BATTLE_QA.md](BATTLE_QA.md) and [CHUMP_AUTONOMY_TESTS.md](CHUMP_AUTONOMY_TESTS.md) for QA framework.

---

## 9. Roadmaps and future work

**Mabel as driver:** Autonomous heartbeat, unified reporting, research, peer_sync, mutual supervision, shared brain, hybrid inference, verify round — see [ROADMAP_MABEL_DRIVER.md](ROADMAP_MABEL_DRIVER.md). **Mabel takes over the farm:** Migrate Mac-local roles (Farmer Brown, Sentinel, Heartbeat Shepherd) to Mabel on the Pixel — see [ROADMAP_MABEL_ROLES.md](ROADMAP_MABEL_ROLES.md). **ADB and network:** [ROADMAP_ADB.md](ROADMAP_ADB.md), [NETWORK_SWAP.md](NETWORK_SWAP.md). Future: Scout/PWA as primary interface with bot switcher (Chump vs Mabel), OCR/screen capture, more watch rounds.

- See [ECOSYSTEM_VISION.md](ECOSYSTEM_VISION.md) and [ROADMAP.md](ROADMAP.md) for overall priorities.
- See [CLOSING_THE_GAPS.md](CLOSING_THE_GAPS.md) and [FLEET_ROLES.md](FLEET_ROLES.md) for fleet expansion.

---

## 10. Reference

**Scripts:** deploy: `deploy-all-to-pixel.sh`, `deploy-mabel-to-pixel.sh`; Mabel heartbeat: `heartbeat-mabel.sh`; farm monitor: `mabel-farmer.sh`; restart: `restart-mabel-bot-on-pixel.sh`, `restart-mabel-heartbeat.sh`; mutual supervision: `restart-chump-heartbeat.sh`, `verify-mutual-supervision.sh`. **Locations:** Pixel: `~/chump` (bin, .env, logs, chump-brain); Mac: Chump repo. **Logs:** `~/chump/logs/heartbeat-mabel.log`, `~/chump/logs/mabel-report-*.md`, `~/chump/logs/mabel-farmer.log`, `~/chump/logs/companion.log`. **Discord:** Mabel app ID 1478435625266053333; test DM user ID (e.g. 377601792764018698) in OPERATIONS or env.

- See [SCRIPTS_REFERENCE.md](SCRIPTS_REFERENCE.md) for scripts taxonomy.
- See [ANDROID_COMPANION.md](ANDROID_COMPANION.md) for SSH config, Termux:Boot, and troubleshooting.
- See [CHUMP_BRAIN.md](CHUMP_BRAIN.md) for shared brain (Mabel + Chump).

---

## References

- **Chump dossier (overview including Mabel):** [DOSSIER.md](DOSSIER.md) — section 7 is "Mabel, Pixel, and fleet."
- **Documentation index:** [00-INDEX.md](00-INDEX.md) — master list of all docs in dossier order.
- **Day-to-day:** [README.md](README.md) — run, roadmaps, brain, Mabel, reference.
