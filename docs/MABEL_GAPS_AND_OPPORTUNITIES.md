# Mabel: Gaps and Opportunities (Bot / AI Agent Focus)

Scope: **Bot and AI agent work only** — no camera, OCR, ADB-from-Pixel, or other device-specific features. Focus: heartbeat rounds, tools, A2A, reporting, task coordination, inference, and fleet symbiosis.

See [MABEL_DOSSIER.md](MABEL_DOSSIER.md), [ROADMAP_MABEL_DRIVER.md](ROADMAP_MABEL_DRIVER.md), and [FLEET_ROLES.md](FLEET_ROLES.md) for context.

---

## Current state (what’s in place)

- **Heartbeat** ([heartbeat-mabel.sh](scripts/heartbeat-mabel.sh)): patrol, research, report, intel, sentinel, verify, peer_sync. Patrol runs `mabel-farmer.sh` then agent; shared brain pull at round start, push at round end.
- **A2A:** `message_peer` tool; Chump persists last reply to `brain/a2a/chump-last-reply.md` ([context_assembly.rs](src/context_assembly.rs)) so Mabel can read it in peer_sync.
- **Tasks:** Assignee column and task create/list/update with assignee (chump | mabel | jeff | any) in [task_db.rs](src/task_db.rs) and [task_tool.rs](src/task_tool.rs); Web API supports assignee filter and update.
- **Hybrid inference:** `MABEL_HEAVY_MODEL_BASE` for research/report; patrol/intel/verify/peer_sync use local model.
- **Cascade:** When local llama-server is down and cascade has cloud slots, heartbeat continues (cascade-only).
- **Mutual supervision:** Scripts exist (`restart-chump-heartbeat.sh`, `restart-mabel-heartbeat.sh`); Chump’s work round and Mabel’s patrol prompt include “check other’s heartbeat log and restart if stale.” Validation gate: run [verify-mutual-supervision.sh](scripts/verify-mutual-supervision.sh); see [OPERATIONS.md](OPERATIONS.md).

---

## Gaps (addressed or documented)

### 1. Peer_sync read path

- **Was:** PEER_SYNC_PROMPT said “message_peer read_latest if available” but no such tool exists; only the brain file exists. Chump writes `chump-last-reply.md` on every Discord reply (and on session close) via `record_last_reply` in [context_assembly.rs](src/context_assembly.rs).
- **Addressed:** Prompt updated to state that the brain file is the only source. No `message_peer read_latest` tool; optional future work: tool or brain file that both sides update on each message for tighter sync.

### 2. Mutual supervision validation

- **Addressed:** [verify-mutual-supervision.sh](scripts/verify-mutual-supervision.sh) exists and checks Mac→Pixel (restart Mabel) and Chump restart on Mac. [OPERATIONS.md](OPERATIONS.md) documents it as the validation gate.

### 3. On-demand status

- **Addressed:** When Mabel receives `!status` or “status report” in Discord, the handler reads the latest `logs/mabel-report-*.md` and replies in channel (see [discord.rs](src/discord.rs) `latest_mabel_report` and on-demand status branch).

### 4. Single fleet report done criterion

- **Addressed:** [OPERATIONS.md](OPERATIONS.md) documents the done criterion (report format stable, on-demand !status works) and unload step for Mac hourly-update.

### 5. Task assignee vs routing logic

- **Addressed:** Chump’s work round context now includes “Tasks for Chump” (assignee=chump) so he prefers tasks Mabel created for him ([context_assembly.rs](src/context_assembly.rs)).

### 6. Report round structure

- **Addressed:** REPORT_PROMPT in [heartbeat-mabel.sh](scripts/heartbeat-mabel.sh) now requires exact section headers: `## FLEET HEALTH`, `## CHUMP`, `## MABEL`, `## NEEDS ATTENTION`.

### 7. Verify round and episode shape

- **Documented:** Verify round SSHs to Mac, reads Chump’s last episode (summary, detail) from SQLite, and infers “was this a code change?” then runs `cargo test`. There is no dedicated “last_code_change” or episode tag in the codebase; the model infers from episode text. If episode summary/detail are vague, Mabel may skip verify or run tests when not needed. Future improvement: optional episode tag or `code_change` flag in episode_db for more reliable detection.

### 8. Intel/research topic discipline

- **Addressed:** INTEL_PROMPT now instructs: if `memory_brain intel/intel-topics.txt` exists, read it and pick 1–2 topics from the list; otherwise use the default list (Rust agent patterns, llama.cpp, Discord bot best practices, etc.).

### 9. CHUMP_CLI_ALLOWLIST

- **Documented:** [OPERATIONS.md](OPERATIONS.md) “CHUMP_CLI_ALLOWLIST (Mabel on Pixel)” specifies required commands (ssh, curl, sqlite3) and recommends a sensible allowlist; empty allowlist is a security risk.

### 10. Mabel self-heal (Pixel)

- **Confirmed and documented:** [mabel-farmer.sh](scripts/mabel-farmer.sh) implements local fix when `MABEL_FARMER_FIX_LOCAL=1` (default): when diagnosis sets `need_fix_local=1` (Pixel llama-server or bot down), it runs `run_local_fix`, which starts `./start-companion.sh` in the background. [OPERATIONS.md](OPERATIONS.md) updated accordingly.

---

## Opportunities (high impact, bot/agent only)

- **Close peer_sync loop:** Chump already writes `chump-last-reply.md` on every a2a reply. Optional: add a “read last a2a message” capability (e.g. tool or shared brain file updated on each message) so Mabel doesn’t depend only on session-close timing.
- **On-demand !status:** Implemented; Mabel replies with latest report when asked `!status` or “status report” in Discord.
- **Retire Mac hourly-update:** When report is stable and !status works, unload per OPERATIONS “Single fleet report (done criterion).”
- **Task routing:** Chump’s work round now loads “Tasks for Chump”; Mabel’s rounds can list assignee=mabel tasks in context if desired (e.g. in patrol/research prompts).
- **Structured report:** Required sections in place; optional: small JSON summary for downstream briefing.
- **Verify round robustness:** Optional: add episode tag or `code_change` flag so verify round doesn’t rely only on free-form episode text.
- **Intel topics file:** Create `chump-brain/intel/intel-topics.txt` (one topic per line) for rotating, high-value topics.
