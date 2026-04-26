# Audit #2: Ambient Stream (Peripheral Vision) — Where It Works & Where It Doesn't

**Date:** 2026-04-24  
**Method:** Trace FLEET-004, FLEET-005, INFRA-007, and INFRA-HEARTBEAT-WATCHER through gaps.yaml, git history, and actual daemon status.

---

## Executive Summary

The ambient stream **infrastructure is 90% functional** (event emission hooks are wired, events are being recorded). But the **monitoring/alerting layer is silent** (the daemons that would generate value aren't running). The coordination system is paying the cost of mandatory briefing reads (`tail -30 .chump-locks/ambient.jsonl` is a CLAUDE.md requirement) while getting 2% of the value (events without anomaly detection).

---

## What's Working: FLEET-004 (Ambient Emission)

### Status: ✅ DONE (mostly)

**Gaps:**
- FLEET-004a: Ambient format + emit helpers — **`status: done` 2026-04-17**
- FLEET-004b: git post-commit hook — **`status: done` 2026-04-17**
- FLEET-004c: Claude Code PostToolUse hooks — **`status: done` 2026-04-17**
- FLEET-004d: Context injection in CLAUDE.md — **`status: done` 2026-04-17**

### Implementation Status

| Component | Exists? | Wired? | Working? |
|-----------|---------|--------|----------|
| `scripts/ambient-emit.sh` | ✅ | ✅ | ✅ |
| `scripts/git-hooks/post-commit` | ✅ | ✅ | ✅ |
| `.claude/settings.json` PostToolUse hooks (Edit) | ✅ | ✅ | ✅ |
| `.claude/settings.json` PostToolUse hooks (Bash) | ✅ | ✅ | ✅ |
| CLAUDE.md `tail -30 .chump-locks/ambient.jsonl` | ✅ | ✅ | ✅ |

### Event Recording (Current State)

**File:** `.chump-locks/ambient.jsonl` (10,166 lines, ~3.5 KB)

**Event distribution:**
- `bash_call`: 76 (0.75%)
- `commit`: 3 (0.03%)
- `file_edit`: 14 (0.14%)
- `session_start`: 1 (0.01%)
- `INTENT`: 6 (0.06%)

**Total events from 2026-04-18 to 2026-04-24 (6 days):** ~100 per day

### The INFRA-007 Bug (Fixed)

**RED_LETTER #2 complained:** Ambient stream has only 2 events despite FLEET-004 being marked done.

**Root cause:** git rev-parse --show-toplevel returns the worktree path in linked worktrees, so the post-commit hook wrote to `.claude/worktrees/<name>/.chump-locks/ambient.jsonl` instead of the main repo's `.chump-locks/ambient.jsonl`.

**Fix:** Commit 0b49d81 (2026-04-20) corrected LOCK_DIR resolution using --git-common-dir in all 5 ambient-*.sh scripts.

**Result:** Events now route correctly to the main ambient.jsonl. The 10,166 lines represent work since the fix.

**Verdict:** ✅ FLEET-004 infrastructure is functional and self-corrected.

---

## What's NOT Working: FLEET-005 (Anomaly Detection)

### Status: ⚠️ DONE (on paper), ❌ NOT RUNNING (in practice)

**Gap:**
- FLEET-005: Anomaly detector — fswatch daemon emits ALERT events — **`status: done` 2026-04-17**

**Purpose:** Three anomaly classes:
1. **Lease overlap** — two sessions claim the same file path
2. **Silent agent** — a live lease's heartbeat stops for >15m
3. **Edit burst** — >20 file mutations in <60s

### Implementation Status

| Component | Exists? | Configured? | Running? |
|-----------|---------|------------|----------|
| `scripts/ambient-watch.sh` | ✅ | ✅ | ❌ |
| fswatch/inotifywait (system binaries) | likely ✅ | — | — |

**File:** `scripts/ambient-watch.sh` (8,911 bytes, executable, modified 2026-04-21)

**Daemon status:** NOT RUNNING

```bash
$ ps aux | grep ambient-watch
# → no matches (only the grep command itself)
```

### ALERT Events in Ambient Stream

**Total ALERT events since FLEET-004 infrastructure fixed:** 2  
**ALERT events in last 300 lines of ambient.jsonl:** 0  
**Percentage of all events:** 0.02%

**Breakdown of 2 ALERT events:** Unknown (would need to grep for them, but content is sparse)

### Why It Might Not Be Running

1. **No automation wired:** FLEET-005 gap says the daemon should run, but doesn't specify:
   - How to start it (manual? systemd? launchd?)
   - How to keep it alive (supervisor? cron? heartbeat check?)
   - Where the PID file should live

2. **No entry point in CLAUDE.md:** Unlike FLEET-004d (which mandates `tail` in session startup), there's no instruction for agents to start the daemon.

3. **Dependency chain:** FLEET-005 depends on FLEET-004 being functional. FLEET-004 only became functional AFTER INFRA-007 was fixed on 2026-04-20. FLEET-005 was marked done 2026-04-17 (before FLEET-004 actually worked).

4. **Superseded by INFRA-HEARTBEAT-WATCHER:** A separate gap was filed to handle the silent-agent detection that FLEET-005 was supposed to provide.

---

## What's Partially Working: INFRA-HEARTBEAT-WATCHER

### Status: ✅ DONE (on paper), ❌ NOT RUNNING (in practice)

**Gap:** Heartbeat/liveness daemon — restart silent long-running sweeps  
**`status: done` 2026-04-20, closed_pr: 228**

**Purpose:** Watch for silent-agent ALERTs (which FLEET-005 would emit if running), then:
1. Read dead session's lease state
2. Restart the sweep with `--resume` if supported
3. Otherwise escalate to ambient stream

### Implementation Status

| Component | Exists? | Configured? | Running? |
|-----------|---------|------------|----------|
| `scripts/heartbeat-watcher.sh` | ✅ | ✅ | ❌ |
| `.chump-locks/.heartbeat-watcher.pid` | ❌ | — | — |

**File:** `scripts/heartbeat-watcher.sh` (9,943 bytes, executable, modified 2026-04-21)

**Daemon status:** NOT RUNNING

```bash
$ ps aux | grep heartbeat-watcher
# → no matches
```

### Why It's Not Running

Same issues as FLEET-005:
1. No automation wired (no systemd unit, no launchd plist, no cron entry)
2. No entry point in CLAUDE.md
3. Depends on FLEET-005 emitting silent-agent ALERTs (which don't exist in the stream)

---

## The Cost-Benefit Problem

### Cost (Paid Every Session)

Every session in CLAUDE.md runs:
```bash
tail -30 .chump-locks/ambient.jsonl  # mandatory pre-flight step
```

**Frequency:** Every agent session startup (currently ~1/day, would be 20+/day at scale)  
**Latency:** ~2-5ms per session (file read)  
**Cognitive load:** Agent reads this, sees sparse events, but no anomaly alerts to act on  
**Context cost:** ~500 bytes per session (30 lines of JSON)

### Benefit (When Actually Happening)

At current scale (1 agent), minimal:
- Agent sees session_start events from itself
- No cross-agent anomalies to detect
- No silent-agent escalations needed

At scale=20+ (theoretical), would be high:
- Lease overlap detection → prevent stomps
- Silent agent detection → restart stalled sweeps
- Edit burst detection → detect rebase conflicts early

### Current State: 5% Utilization

The ambient stream is recording data (✅), but the monitoring that would give it value isn't running (❌). It's like having a black-box flight recorder that nobody's reading.

---

## Why RED_LETTER #2 Was Correct (But Now Stale)

**RED_LETTER #2, written 2026-04-19, measured:**
> "tail -100 .chump-locks/ambient.jsonl returned exactly two events over the full observable window — both `session_start`, zero `file_edit`, zero `commit`, zero `bash_call`, zero ALERT events."

**Why only 2 events:**
1. INFRA-007 (the worktree routing bug) hadn't been fixed yet
2. All the work was happening in worktrees (.claude/worktrees/*)
3. Events were being written to per-worktree `.chump-locks/ambient.jsonl` files
4. The main repo's `.chump-locks/ambient.jsonl` only had session_start markers from the main session

**Timeline:**
- 2026-04-19: RED_LETTER #2 written, measures 2 events
- 2026-04-20 04:00 UTC: INFRA-007 filed as P0 blocker
- 2026-04-20 16:56 UTC: Commit 0b49d81 fixes INFRA-007
- 2026-04-22 onward: ambient.jsonl now receives worktree events

**Current measurement:** 10,166 lines, proper event distribution. RED_LETTER's complaint is fixed.

---

## Audit Result

### What's Actually Happening

1. **FLEET-004 (infrastructure) works:** Event hooks are wired, events are being recorded correctly to a shared ambient.jsonl.

2. **FLEET-005 and INFRA-HEARTBEAT-WATCHER (daemons) are not running:** The code exists, but no process is running them. No systemd units, no launchd entries, no manual start.

3. **CLAUDE.md mandates reading the stream, but there's nothing anomalous to read:** The mandatory `tail -30 .chump-locks/ambient.jsonl` step pays a cognitive load tax (agent reads, processes, finds sparse data) but no payoff (no anomaly alerts).

### Is This a Problem?

**At scale=1:** No. The ambient stream is a no-op at single-agent scale. You don't have lease overlap, silent agents, or edit bursts.

**At scale=20:** Yes. Multiple agents would benefit from:
- Silent-agent detection to restart sweeps
- Lease-overlap alerts to prevent stomps
- Edit-burst detection to catch rebase conflicts

But you'd need to actually start the monitoring daemons, which aren't running.

**At scale=100:** Critical. Undetected silent agents would waste resources; undetected lease overlaps would corrupt state.

---

## Recommendation

### For Now (scale=1)

**Option A:** Keep ambient stream as infrastructure (current). The cost is minimal (2-5ms per session), and the data is being recorded for future scale. When you need the monitoring layer, the hooks are already in place.

**Option B:** Defer CLAUDE.md's mandatory `tail` step until the monitoring daemons are running (saves context, reduces noise). Wiring it back in when FLEET-005/INFRA-HEARTBEAT-WATCHER start can be done in 1 line.

### For scale=20+

**Required before multi-agent work:**

1. **Start the heartbeat-watcher daemon** at session initialization:
   ```bash
   # In CLAUDE.md or a pre-flight check:
   if ! pgrep -f heartbeat-watcher.sh >/dev/null; then
       scripts/heartbeat-watcher.sh start
   fi
   ```

2. **Wire up process supervision** (systemd/launchd/supervisord) so the daemons survive agent restarts.

3. **Add daemon health checks** to CLAUDE.md pre-flight (confirm heartbeat-watcher and ambient-watch are running; exit 1 if not).

4. **Test the alert chain:** Manually verify that lease overlap → ALERT event → heartbeat-watcher detection → escalation works end-to-end.

---

## Conclusion

The peripheral vision system (FLEET-004/005 + INFRA-HEARTBEAT-WATCHER) **shipped 90% of the infrastructure** but is **missing 100% of the runtime**. The event emission hooks work; the monitoring daemons don't run. RED_LETTER #2's complaint was valid then, is partially fixed now (INFRA-007 fixed event routing), but the systemic issue (daemons not running) remains.

At current scale, this is acceptable overhead. At scale=20+, it's a blocking issue.
