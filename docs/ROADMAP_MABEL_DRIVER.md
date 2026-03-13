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
ROUND_TYPES=(patrol patrol research report patrol intel patrol peer_sync)
```

| Round type | What Mabel does |
|---|---|
| **patrol** | Run `mabel-farmer.sh` inline (not as a separate cron — the heartbeat IS the farmer). Check Mac stack health, check local llama-server, check her own bot process. If anything is wrong: attempt fix via SSH, then notify Jeff if still broken. Log results via episode. |
| **research** | Pick a topic from her task queue or from recent Chump activity (read Chump's latest episodes via SSH + `sqlite3` on the Mac). Use `web_search` + `read_url` to gather info. Store findings in `memory` and `memory_brain`. If a finding suggests a product improvement, create a task and `message_peer` Chump about it. |
| **report** | Generate a unified status report covering both devices. Pull Chump's recent episodes + task status via SSH. Combine with her own patrol data. Send to Jeff via `notify`. Write to `~/chump/logs/mabel-report-{date}.md`. |
| **intel** | Web search for topics relevant to the project: Rust agent patterns, llama.cpp updates, Discord bot best practices, Termux tips, new CLI tools. Store in memory_brain under `intel/`. Create tasks for Chump if something is actionable. |
| **peer_sync** | `message_peer` Chump with: (a) summary of what Mabel did since last sync, (b) any tasks she created for him, (c) any anomalies she spotted. Read Chump's reply in the next peer_sync round (check a2a channel via Discord or parse response). |

**Interval:** 5–10 min per round (lighter than Chump's 8 min since no code compilation). Default 8h duration, same as Chump.

**Script location:** `scripts/heartbeat-mabel.sh` — runs on Pixel, uses Mabel's local model.

**Prompt structure:** Similar to Chump's heartbeat but with Mabel's role baked in. See the script for PATROL_PROMPT, RESEARCH_PROMPT, REPORT_PROMPT, INTEL_PROMPT, PEER_SYNC_PROMPT.

### 1.2 Start/stop integration

- **Termux:Boot** auto-starts the heartbeat alongside the bot: `~/.termux/boot/start-chump.sh` adds the heartbeat. See [ANDROID_COMPANION.md](ANDROID_COMPANION.md#mabel-heartbeat).
- **Chump Menu** (on Mac) gets "Start Mabel heartbeat" / "Stop Mabel heartbeat" entries that SSH into the Pixel.
- **Pause/resume:** Same `logs/pause` file convention as Chump — `touch ~/chump/logs/pause` on the Pixel skips rounds.

### 1.3 Coordinated scheduling with Chump

Both heartbeats run independently but Mabel is aware of Chump's schedule:

- Mabel's patrol rounds check if Chump's heartbeat is healthy (read his log via SSH).
- If Chump's heartbeat crashes, Mabel can restart it: `ssh mac "cd ~/Projects/Chump && pkill -f heartbeat-self-improve; HEARTBEAT_INTERVAL=8m HEARTBEAT_DURATION=8h nohup bash scripts/heartbeat-self-improve.sh >> logs/heartbeat-self-improve.log 2>&1 &"`
- Mabel uses `schedule` tool to set her own reminders (e.g., "check if Chump's PR from last night was merged").

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

## Related Docs

| Doc | Relevance |
|---|---|
| [ROADMAP_MABEL_ROLES.md](ROADMAP_MABEL_ROLES.md) | Phase 1-2 here supersedes and extends this |
| [A2A_DISCORD.md](A2A_DISCORD.md) | peer_sync rounds use message_peer |
| [MABEL_PERFORMANCE.md](MABEL_PERFORMANCE.md) | Timing and tuning for Mabel's model |
| [ANDROID_COMPANION.md](ANDROID_COMPANION.md) | Deploy, Termux setup, Mabel heartbeat |
| [OPERATIONS.md](OPERATIONS.md) | Current ops setup that Mabel will take over |
