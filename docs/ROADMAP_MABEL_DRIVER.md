# Roadmap: Mabel as a Driver

Turn Mabel from a passive monitor + chatbot into an autonomous, proactive agent that fully utilizes the Pixel 8 Pro as an independent compute node with unique capabilities.

---

## The Problem

Mabel currently uses ~5% of the Pixel's potential:

| What she does | What she could do |
|---|---|
| Answers Discord messages | Runs her own heartbeat loop with proactive work |
| Farmer probe every 2 min | Owns unified reporting for the whole fleet |
| Sits on 3B model + Vulkan GPU | Runs research, web intel, and phone automation |
| Has all core tools (memory, tasks, schedule, ego, episode, brain, web_search, message_peer) | Uses them autonomously on a loop, not just on demand |
| Connected to Mac via Tailscale SSH | Actively coordinates with Chump as a peer, not a subordinate |
| Running on a phone with camera, sensors, location, notifications, always-on LTE | Uses none of these |

**After this roadmap:** Mabel is a 24/7 autonomous agent that runs her own work cycles, monitors and heals the fleet, does independent research, controls the phone, files reports, and coordinates with Chump as an equal partner.

---

## Phase 1: Mabel Gets Her Own Heartbeat (highest impact, do first)

**Why:** Without a heartbeat loop, Mabel only acts when spoken to. This single change turns her from reactive to proactive.

### 1.1 `heartbeat-mabel.sh`

A Mabel-specific heartbeat script that runs on the Pixel in Termux. NOT a copy of Chump's `heartbeat-self-improve.sh` — Mabel's round types reflect her role:

```
ROUND_TYPES=(patrol patrol research report patrol intel patrol verify peer_sync)
```

| Round type | What Mabel does |
|---|---|
| **patrol** | Run `mabel-farmer.sh` inline (not as a separate cron — the heartbeat IS the farmer). Check Mac stack health, check local llama-server, check her own bot process. If anything is wrong: attempt fix via SSH, then notify Jeff if still broken. Log results via episode. |
| **research** | Pick a topic from her task queue or from recent Chump activity (read Chump's latest episodes via SSH + `sqlite3` on the Mac). Use `web_search` + `read_url` to gather info. Store findings in `memory` and `memory_brain`. If a finding suggests a product improvement, create a task and `message_peer` Chump about it. |
| **report** | Generate a unified status report covering both devices. Pull Chump's recent episodes + task status via SSH. Combine with her own patrol data. Send to Jeff via `notify`. Write to `~/chump/logs/mabel-report-{date}.md`. |
| **intel** | Web search for topics relevant to the project: Rust agent patterns, llama.cpp updates, Discord bot best practices, Termux tips, new CLI tools. Store in memory_brain under `intel/`. Create tasks for Chump if something is actionable. |
| **verify** | QA round: read Chump's last episode via SSH; if it was a code change, run `cargo test` on the Mac; if tests failed, create a task for Chump and notify Jeff. |
| **peer_sync** | `message_peer` Chump with: (a) summary of what Mabel did since last sync, (b) any tasks she created for him, (c) any anomalies she spotted. Read Chump's reply in the next peer_sync round (check a2a channel via Discord or parse response). |

**Interval:** 5–10 min per round (lighter than Chump's 8 min since no code compilation). Default 8h duration, same as Chump.

**Script location:** `scripts/heartbeat-mabel.sh` — runs on Pixel, uses Mabel's local model.

**Prompt structure:** Similar to Chump's heartbeat but with Mabel's role baked in. See the script for PATROL_PROMPT, RESEARCH_PROMPT, REPORT_PROMPT, INTEL_PROMPT, PEER_SYNC_PROMPT.

### 1.2 Start/stop integration

- **Termux:Boot** auto-starts the heartbeat alongside the bot: `~/.termux/boot/start-chump.sh` adds the heartbeat. See [ANDROID_COMPANION.md](ANDROID_COMPANION.md#mabel-heartbeat).
- **Chump Menu** (on Mac) gets "Start Mabel heartbeat" / "Stop Mabel heartbeat" entries that SSH into the Pixel.
- **Pause/resume:** Same `logs/pause` file convention as Chump — `touch ~/chump/logs/pause` on the Pixel skips rounds.

### 1.3 Coordinated scheduling and mutual supervision

Both heartbeats run independently but each checks the other:

- **Mabel → Chump:** Patrol rounds check Chump's heartbeat log via SSH (`tail` on `logs/heartbeat-self-improve.log`). If the last round was >30 min ago or shows repeated failures, Mabel runs `scripts/restart-chump-heartbeat.sh` on the Mac via SSH. If that script exits non-zero, Mabel notifies Jeff.
- **Chump → Mabel:** When `PIXEL_SSH_HOST` is set on the Mac, Chump's work round starts with a "check Mabel" step: SSH to Pixel, `tail` Mabel's `logs/heartbeat-mabel.log`. If stale >30 min, Chump runs `scripts/restart-mabel-heartbeat.sh` on the Pixel via SSH; if restart fails, Chump notifies Jeff.
- Scripts: `scripts/restart-chump-heartbeat.sh` (Mac) and `scripts/restart-mabel-heartbeat.sh` (Pixel). Both exit 0 on success, 1 on failure so the supervising agent can notify.
- Mabel uses `schedule` tool to set her own reminders (e.g., "check if Chump's PR from last night was merged").

**Env (Mac .env, for Chump to check Mabel):** `PIXEL_SSH_HOST=termux`, `PIXEL_SSH_PORT=8022` (or your Pixel SSH host from `~/.ssh/config`).

**Env vars (Pixel .env):**

```bash
MABEL_HEARTBEAT_DURATION=8h
MABEL_HEARTBEAT_INTERVAL=5m
MABEL_HEARTBEAT_RETRY=1
```

**CHUMP_CLI_ALLOWLIST on Pixel:** For patrol, research, and report rounds, Mabel needs `ssh`, `curl`, and optionally `sqlite3`. Set e.g. `CHUMP_CLI_ALLOWLIST=curl,ssh,sqlite3,date,uptime` (plus any other commands you allow). See script header in `scripts/heartbeat-mabel.sh`.

---

## Phase 2: Mabel Owns Reporting (unified single pane of glass)

**Why:** Right now reporting is fragmented — Chump's hourly updates, mabel-farmer logs, morning reports. Mabel should own ALL reporting to Jeff.

### 2.1 Unified status report (replaces hourly-update-to-discord on Mac)

Mabel's report round generates one consolidated report:

```
Mabel Report — 2026-03-13 14:00 UTC
─────────────────────────────────────
FLEET HEALTH
  Mac: Ollama ✓  Model ✓  Embed ✓  Discord ✓  Heartbeat ✓ (last round 4m ago)
  Pixel: llama-server ✓  Mabel bot ✓  Heartbeat ✓

CHUMP (last 4h)
  Completed: task #42 (fix unwrap in memory_tool), task #43 (clippy warnings)
  In progress: task #44 (context assembly)
  Blocked: none
  PRs: #18 open (awaiting review)

MABEL (last 4h)
  Patrols: 24/24 clean
  Research: stored 3 findings (llama.cpp 4.1 release, new Termux package for OCR)
  Created: task #45 for Chump (update llama.cpp build script for 4.1)

NEEDS ATTENTION
  Nothing — all systems nominal.
```

### 2.2 Retire Mac-side reporting

Once Mabel's report is stable:
- Unload `ai.chump.hourly-update-to-discord` launchd job on Mac.
- Remove hourly update from Chump's responsibilities.
- Chump still sends ad-hoc `notify` for blocking issues / PR ready, but scheduled reporting is 100% Mabel's.

### 2.3 On-demand status

Mabel already has `mabel_status_message()` for "what are you up to?" — extend this to be a full fleet report when Jeff says `!status` or "status report" in the a2a channel or DMs.

---

## Phase 3: Mabel as Research & Intel Agent

**Why:** Mabel has web_search and read_url but only uses them on request. She should be actively gathering intelligence that feeds Chump's work queue.

### 3.1 Research round prompt

Implemented in `heartbeat-mabel.sh` RESEARCH_PROMPT. Topics: Chump's recent work, task queue, project needs; web_search + read_url; store in memory and memory_brain; task create + message_peer if actionable.

### 3.2 Intel topics database

Mabel maintains `~/chump/intel-topics.txt` (or a memory_brain file) listing topics to cycle through: llama.cpp, Rust async, Discord/serenity, Termux, Tailscale, Android automation, agent frameworks, SQLite/FTS5.

### 3.3 Cross-pollination with Chump

Mabel stores findings, creates tasks, message_peer to Chump; Chump's next work round picks up. For Chump's brain, Mabel can SSH and append to files under chump-brain/intel/.

---

## Phase 4: Phone as a Platform (Termux:API + Device Capabilities)

**Why:** The Pixel has hardware that the Mac doesn't — camera, GPS, cellular, sensors. Mabel should leverage these (Termux:API, CLI allowlist or native device tool). See doc for command table and battery-aware pacing, notification fallback.

---

## Phase 5: Mabel Drives ADB Phone Control

**Why:** ADB tool exists but only Chump (on Mac) uses it. Mabel is ON the phone — local device control, ADB relay for Chump, closed-loop screen automation.

---

## Phase 6: Mabel as Task Router & Delegation Engine

**Why:** Route tasks to the right agent; shared task visibility via SSH + SQLite; follow-up scheduling with `schedule`.

---

## Phase 7: Model Upgrade Path

**Why:** 3B is fast but limited. Hybrid inference (local for patrol, Mac for heavy) and/or 7B local on Pixel.

---

## Implementation Order

| Sprint | Phase | Items | Effort | Impact |
|---|---|---|---|---|
| **1** | Phase 1 | `heartbeat-mabel.sh` with patrol + research + report + peer_sync rounds | 1-2 days | **Critical** |
| **1** | Phase 2.1 | Unified report in the report round prompt | included above | **High** |
| **2** | Phase 4.1-4.2 | Termux:API, expand CLI allowlist | 0.5 day | Medium |
| **2** | Phase 3 | Research round, intel topics, cross-pollination | 1 day | **High** |
| **3** | Phase 6 | Task triage, shared task visibility, follow-up scheduling | 1 day | **High** |
| **3** | Phase 2.2-2.3 | Retire Mac reporting, on-demand !status | 0.5 day | Medium |
| **4** | Phase 7.1 | Hybrid inference | 0.5 day | Medium |
| **4** | Phase 5 | ADB relay, local device control | 1-2 days | Medium |
| **5** | Phase 7.2 | 7B model on Pixel | 0.5 day | Medium |

---

## Sprints 6–10 (after Phase 1)

| Sprint | Focus | Deliverables |
|--------|--------|--------------|
| **6** | Mutual supervision | `restart-chump-heartbeat.sh` (Mac), `restart-mabel-heartbeat.sh` (Pixel); Mabel patrol harden; Chump heartbeat "check Mabel" step; `PIXEL_SSH_*` on Mac |
| **7** | OCR on Pixel | tesseract install; `screen-ocr.sh`; `CHUMP_CLI_ALLOWLIST` update; doc |
| **8** | Shared brain | git pull at Mabel round start, git push at round end; Chump pull at session/round start; doc |
| **9** | QA verify | `verify` round type + VERIFY_PROMPT in heartbeat-mabel.sh |
| **10** | Hybrid + recipes | `MABEL_HEAVY_MODEL_BASE` routing; memory_brain/recipes/ usage (future) |

### Sprint 6: Mutual supervision

Each agent checks the other's heartbeat log every patrol/work cycle. If stale (>30 min), restart via script; if restart fails, notify Jeff. See Phase 1.3 above. Scripts: `scripts/restart-chump-heartbeat.sh`, `scripts/restart-mabel-heartbeat.sh`.

### Sprint 7: OCR on Pixel

Mabel runs `scripts/screen-ocr.sh` (screencap + tesseract) to read screen text without a vision model. Install: `pkg install tesseract` in Termux. Add `tesseract` to `CHUMP_CLI_ALLOWLIST`. See [ANDROID_COMPANION.md](ANDROID_COMPANION.md#ocr-on-pixel-screen-ocr).

### Sprint 8: Shared brain via git

One shared `chump-brain/` git repo. Mabel: pull at round start, push at round end (when changes). Chump: pull at heartbeat round start. See [CHUMP_BRAIN.md](CHUMP_BRAIN.md#shared-brain-mabel--chump).

### Sprint 9: Mabel as QA/verification layer

`verify` round type: Mabel reads Chump's last episode; if it was a code change, SSHs to Mac and runs `cargo test`; if tests failed, creates a task for Chump and notifies Jeff. Purely prompt + round in `heartbeat-mabel.sh`.

### Sprint 10: Hybrid inference and automation recipes

- **Hybrid inference:** Set `MABEL_HEAVY_MODEL_BASE` (e.g. Mac 14B API URL) in Pixel `.env`. Research and report rounds use it; patrol/intel/peer_sync/verify stay on local 3B.
- **Automation recipes (future):** Named procedures in `memory_brain/recipes/` (e.g. check-gmail.md: open Gmail → wait → screencap → OCR → report). Mabel reads recipe and runs steps. Build after OCR and screen control are solid.

### Nice to have (build when 6–10 are solid)

- Automation recipes (Sprint 10).
- Hybrid inference routing (Sprint 10).
- **Web dashboard:** Static HTML from Pixel (or Tailscale): fleet status, task queues, recent episodes, last report. Mabel's report round already has the data; write to a dir and serve with `python3 -m http.server 8080` in Termux.

### Skip entirely (no implementation)

- Foreground Android service (Termux:Boot + wake lock is enough).
- Bluetooth/NFC for the agent (no clear use case).
- Full accessibility service integration (ADB + OCR is enough for now).
- Local embeddings on Pixel (FTS5 keyword search sufficient).
- Cloud VPS third node until two-node setup is solid.

---

## Two-node setup: what's in place / what to bring in

### In place (done)

| Item | Where | Notes |
|------|--------|------|
| **Brain repo** | [github.com/repairman29/chump-brain](https://github.com/repairman29/chump-brain) | Private repo; Mac has local clone in `chump-brain/`, Pixel has clone at `~/chump/chump-brain`. Pixel deploy key (SSH) added for push/pull. Both heartbeats run git pull/push. See [CHUMP_BRAIN.md](CHUMP_BRAIN.md#shared-brain-mabel--chump). |
| **Mutual supervision** | Mac + Pixel | `PIXEL_SSH_HOST=termux`, `PIXEL_SSH_PORT=8022` in Mac `.env`. Restart scripts on both sides; patrol/work prompts check the other's heartbeat log and restart if stale. |
| **OCR on Pixel** | Termux | `pkg install tesseract`; `CHUMP_CLI_ALLOWLIST` includes `tesseract`; `scripts/screen-ocr.sh` deployed. |
| **Hybrid inference** | Pixel `.env` | `MABEL_HEAVY_MODEL_BASE=http://<MAC_TAILSCALE_IP>:8000/v1` so research/report rounds use the Mac 14B; patrol/intel/verify/peer_sync use local 3B. |
| **iPhone inference (optional)** | Mac + Pixel `.env` | Third node: iPhone inferrlm at Tailscale IP:8889 (e.g. 10.1.10.175:8889). Use for CHUMP_FALLBACK_API_BASE, CHUMP_WORKER_API_BASE, or MABEL_HEAVY_MODEL_BASE. See [INFERENCE_MESH.md](INFERENCE_MESH.md). |

### What to bring in (optional / one-time)

| Item | Action |
|------|--------|
| **Mac API reachable from Pixel** | For hybrid inference, the Mac’s model API (e.g. 8000) must listen on an interface the Pixel can reach (e.g. `0.0.0.0:8000` or Tailscale IP). If it’s bound to `127.0.0.1` only, change the server bind or use a small proxy so the Pixel can call it. |
| **CHUMP_BRAIN_PATH** | Only if you use a path other than `chump-brain` (Mac) or `~/chump/chump-brain` (Pixel). Defaults are already set in the scripts. |
| **New Pixel / reinstall** | Re-run Termux setup, deploy with `./scripts/deploy-all-to-pixel.sh termux`, install tesseract, set `.env` (or re-apply apply-mabel-badass-env.sh), add Pixel SSH key as deploy key on `repairman29/chump-brain` again, clone `chump-brain` into `~/chump/chump-brain`. |

---

## Related Docs

| Doc | Relevance |
|---|---|
| [ROADMAP_MABEL_ROLES.md](ROADMAP_MABEL_ROLES.md) | Phase 1-2 here supersedes and extends this |
| [A2A_DISCORD.md](A2A_DISCORD.md) | peer_sync rounds use message_peer |
| [MABEL_PERFORMANCE.md](MABEL_PERFORMANCE.md) | Timing and tuning for Mabel's model |
| [ANDROID_COMPANION.md](ANDROID_COMPANION.md) | Deploy, Termux setup, Mabel heartbeat |
| [OPERATIONS.md](OPERATIONS.md) | Current ops setup that Mabel will take over |
| [INFERENCE_MESH.md](INFERENCE_MESH.md) | Mac + Pixel + optional iPhone inference nodes; env for fallback, delegate, Mabel heavy |
