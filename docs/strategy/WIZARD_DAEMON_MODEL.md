# Wizard-Daemon Model — META-109 Phase 1

> The DRIVE primitive that ties THE FLOOR's BUILD primitives into an autonomous loop.
> Default: **OFF**. Operator opt-in required.

## What it does (Phase 1)

`scripts/coord/wizard-daemon.sh` runs every 5 minutes via launchd. Each cycle:

1. **Step 1 — Poll + classify** open PRs from the cache-first PR queue. Each PR
   gets a state class: `CLEAN+armed`, `BLOCKED+stale-base`, `BLOCKED+real-fails`,
   `BLOCKED+cascading`, `DIRTY`, or `CONFLICTING`.

2. **Step 2 — Recovery-queue** for `BLOCKED+stale-base` and `BLOCKED+cascading`
   PRs: emits an `operator_recovery_requested` event so
   `recovery-queue-service.sh` can admin-merge the cluster (rate-limited to
   3 cycles/hr fleet-wide by the service, and 3 emits/cycle by the daemon).

6. **Step 6 — Stall broadcast** for `fleet_stalled` or `worker_stuck` ambient
   events within the last 10 minutes: broadcasts a CRIT message to URGENT-INBOX
   so any active operator or agent sees it on their next tool call. Deduped:
   only one broadcast per lookback window.

**Safety guards (mandatory — never bypassed):**
- Refuses to act when `chump health --temp` reports **HOT** (cascade preventer).
- Refuses to act on any PR with `mergeStateStatus=CONFLICTING` (real conflicts
  need human judgment — the daemon will not touch them).
- Stands down immediately when a fleet-hold is active (cluster-detector owns that
  signal; daemon waits for hold to clear).

**Phase 2 (follow-up gap):**
- Step 3 — real-fails → URGENT-INBOX with author tag
- Step 4 — pickable gap dispatch via `chump --execute-gap`
- Step 5 — cascade rebase after cluster clears

## When to enable

Enable **only after** all three preconditions are met:

| Precondition | Why |
|---|---|
| Sprint 1 floor primitives stable (INFRA-2008/2013/2029 shipped + soak) | Daemon needs real floor-temp + fleet_stalled + worker_stuck signals |
| Operator has validated one full recovery-queue cycle interactively | Confirms drop-window + admin-merge path works before unattended mode |
| Fleet waste rate < 20% for 48h | Ensures daemon won't amplify existing instability |

Run `chump health --slo-check` before enabling. It must exit 0.

## How to enable

```bash
# Option A: reinstall with --enable flag (writes ENABLED=1 into plist env)
bash scripts/setup/install-wizard-daemon-launchd.sh --enable

# Option B: edit the plist manually then reload
# In ~/Library/LaunchAgents/com.chump.wizard-daemon.plist:
#   <key>CHUMP_WIZARD_DAEMON_ENABLED</key><string>1</string>
launchctl unload ~/Library/LaunchAgents/com.chump.wizard-daemon.plist
launchctl load -w ~/Library/LaunchAgents/com.chump.wizard-daemon.plist
```

## How to monitor

```bash
# Live log (launchd captures both stdout + stderr)
tail -f .chump-locks/wizard-daemon.log

# Ambient stream — wizard-daemon events
grep '"source":"wizard_daemon"' .chump-locks/ambient.jsonl | tail -20

# Count actions per step in last run
grep '"kind":"wizard_daemon_action"' .chump-locks/ambient.jsonl | tail -50 \
  | python3 -c "
import json, sys, collections
counts = collections.Counter()
for line in sys.stdin:
    try:
        d = json.loads(line)
        counts[(d.get('step','?'), d.get('decision','?'))] += 1
    except: pass
for k,v in sorted(counts.items()): print(f'  {k[0]:20s} {k[1]:30s} {v}')
"

# Safety refusals (should be rare; frequent = fleet is unstable)
grep '"kind":"wizard_daemon_safety_refusal"' .chump-locks/ambient.jsonl | tail -10

# Recovery-queue emits this cycle
grep '"decision":"recovery_queue_emitted"' .chump-locks/ambient.jsonl | tail -10
```

Key ambient event kinds to watch:

| Kind | Meaning |
|---|---|
| `wizard_daemon_action` | Normal operation — carries `step`, `target`, `decision` |
| `wizard_daemon_paused` | Kill-switch active; daemon did nothing |
| `wizard_daemon_safety_refusal` | HOT-temp or CONFLICTING-PR guard fired |

## How to disable

**Immediate (operator emergency):**
```bash
# Method 1: environment kill-switch (takes effect on next launchd invocation)
launchctl setenv CHUMP_WIZARD_DAEMON_PAUSE 1

# Method 2: unload the plist entirely
launchctl unload ~/Library/LaunchAgents/com.chump.wizard-daemon.plist
```

**Persistent disable:**
```bash
# Remove the plist + kill the running cycle (if any)
bash scripts/setup/install-wizard-daemon-launchd.sh --uninstall
```

**Disable via autopilot:**
```bash
# fleet-autopilot stop also stops wizard-daemon (it's in AUTOPILOT_LAYERS)
bash scripts/coord/fleet-autopilot.sh stop
```

## Rollback procedure

If the daemon causes unintended recovery-queue cycles or CRIT broadcasts:

1. **Disable immediately**: `launchctl unload ~/Library/LaunchAgents/com.chump.wizard-daemon.plist`
2. **Audit what it did**: `grep '"source":"wizard_daemon"' .chump-locks/ambient.jsonl | tail -50`
3. **Check recovery-queue**: `grep '"kind":"operator_recovery_executed"' .chump-locks/ambient.jsonl | tail -20`
4. **If a bad recovery cycle ran**: the recovery-queue-service writes a ruleset backup before
   modifying branch protections. Find it: `ls .chump-locks/ruleset-backup-*.json | tail -3`
   and restore manually via `gh api -X PUT repos/<owner>/<repo>/rulesets/<id> --input <backup>`.
5. **File a gap** describing what happened so the daemon's classification logic can be improved.
6. **Re-enable only** after the root cause is understood and fixed.

## Rate limits

| Limit | Where enforced | Value |
|---|---|---|
| Recovery-queue emits per daemon cycle | `wizard-daemon.sh` `CHUMP_WIZARD_RECOVERY_RATE_LIMIT` | 3/cycle |
| Recovery-queue cycles per hour | `recovery-queue-service.sh` | 3/hr |
| Step 6 broadcast dedup | `wizard-daemon.sh` lookback window | 1 per `CHUMP_WIZARD_STALL_LOOKBACK_S` (600s) |

To override for testing: `CHUMP_WIZARD_RECOVERY_RATE_LIMIT=1 CHUMP_WIZARD_DAEMON_ENABLED=1 bash scripts/coord/wizard-daemon.sh`

## Architecture diagram

```
launchd (5min)
    └─ wizard-daemon.sh (Phase 1)
         │
         ├─ GUARD: ENABLED=1? (default: skip)
         ├─ GUARD: PAUSE=1? (kill-switch: emit paused + exit)
         ├─ GUARD: fleet-hold active? (stand down)
         ├─ GUARD: floor_temp HOT? (safety refusal + exit)
         │
         ├─ Step 1: cache_query_open_prs OR gh pr list
         │     └─ per PR: cache_lookup_pr OR gh pr view
         │           └─ classify → {CLEAN+armed, BLOCKED+stale-base, ...}
         │                 └─ route to Step 2
         │
         ├─ Step 2: BLOCKED+stale-base / BLOCKED+cascading
         │     ├─ rate-limit check (max 3/cycle)
         │     ├─ SAFETY: CONFLICTING → refuse (emit safety_refusal)
         │     └─ recovery-queue-emit.sh --prs <N> --reason "..."
         │
         └─ Step 6: scan ambient.jsonl for fleet_stalled / worker_stuck
               ├─ dedup: skip if broadcast_crit in last 600s
               └─ broadcast-urgent.sh --urgency CRIT "..."
```
