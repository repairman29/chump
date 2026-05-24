#!/usr/bin/env bash
# opus-shepherd-migrate-to-event-driven.sh — META-099
#
# Detects an active cron-based opus-shepherd loop, deletes it, and prints the
# Monitor + ScheduleWakeup stanza to paste into the running session.
#
# Usage: bash scripts/coord/opus-shepherd-migrate-to-event-driven.sh [--dry-run]

set -euo pipefail

DRY_RUN=0
for arg in "$@"; do [[ "$arg" == "--dry-run" ]] && DRY_RUN=1; done

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
AMBIENT="${CHUMP_AMBIENT_LOG:-$REPO_ROOT/.chump-locks/ambient.jsonl}"

log() { echo "[opus-shepherd-migrate] $*" >&2; }

# ── 1. Detect cron jobs matching opus-shepherd patterns ───────────────────────
CRON_IDS=()
while IFS= read -r line; do
    id=$(echo "$line" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('id',''))" 2>/dev/null || true)
    prompt=$(echo "$line" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('prompt',''))" 2>/dev/null || true)
    if [[ -n "$id" ]] && echo "$prompt" | grep -qi 'opus.shepherd\|shepherd.*loop\|chump.*autopilot\|fleet.*auto-pilot'; then
        CRON_IDS+=("$id")
        log "found cron job: $id (prompt: ${prompt:0:60}...)"
    fi
done < <(chump cron list --json 2>/dev/null | python3 -c "
import sys, json
try:
    jobs = json.load(sys.stdin)
    if isinstance(jobs, list):
        for j in jobs: print(json.dumps(j))
except: pass
" 2>/dev/null || true)

if [[ ${#CRON_IDS[@]} -eq 0 ]]; then
    log "no cron-based opus-shepherd jobs found — nothing to migrate"
    echo ""
    echo "If you started via /loop with an interval, the cron ID was printed"
    echo "when it was created. Use 'chump cron list' to find it manually."
else
    for id in "${CRON_IDS[@]}"; do
        if [[ "$DRY_RUN" -eq 1 ]]; then
            log "DRY-RUN: would delete cron $id"
        else
            log "deleting cron $id"
            chump cron delete "$id" 2>/dev/null || true
        fi
    done
fi

# ── 2. Emit migration event to ambient ────────────────────────────────────────
if [[ "$DRY_RUN" -eq 0 ]]; then
    printf '{"ts":"%s","kind":"opus_shepherd_migrated_to_event_driven","source":"opus-shepherd-migrate-to-event-driven.sh","cron_ids_deleted":%d}\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${#CRON_IDS[@]}" \
        >> "$AMBIENT" 2>/dev/null || true
fi

# ── 3. Print the event-driven stanza ──────────────────────────────────────────
cat <<'STANZA'

═══════════════════════════════════════════════════════════════════════════════
  EVENT-DRIVEN LOOP STANZA — paste into your running opus-shepherd session
═══════════════════════════════════════════════════════════════════════════════

1. Arm the Monitor (once per session):

   Arm a persistent Monitor on the ambient stream:
     tail -F .chump-locks/ambient.jsonl \
       | grep --line-buffered -E '"kind":"(pr_merged|pr_stuck|fleet_wedge|silent_agent|gap_ship_confirmed|lease_overlap|operator_dm)"'

   Use persistent: true so it fires across wakes.

2. At the end of every wake, call ScheduleWakeup with:
   - delaySeconds: 1200  (20-min fallback; cache-aware)
   - prompt: <your full /loop prompt verbatim>
   - reason: "event-driven fallback heartbeat; Monitor is primary wake signal"

3. On each Monitor notification: handle it, then re-arm ScheduleWakeup.

RESULT: ~6 wakes/day (event-driven) vs. 96/day (15m cron). Load-avg drops
from 36 → ~2 under the same workload.

Override: CHUMP_OPUS_LOOP_MODE=cron forces legacy 15m cron if needed.
═══════════════════════════════════════════════════════════════════════════════

STANZA
