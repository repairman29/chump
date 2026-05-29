#!/usr/bin/env bash
# dispatch-flatline-detector.sh — INFRA-2101: catch autopilot "alive but idle".
#
# Reads ambient.jsonl for `sub_agent_dispatched` events over a rolling window.
# When count is 0 for the entire window AND autopilot heartbeat IS firing
# (so we're definitely "alive"), emits kind=dispatch_flatline alert so the
# operator sees it in the SessionStart digest.
#
# Precedent (2026-05-28): autopilot heartbeated 42 times/24h, daemon_tick
# 80 times, and STILL dispatched 0 sub-agents. The fleet was alive but
# producing nothing. No existing alert caught this because all SLOs were
# measuring per-daemon health, not the dispatch chain end-to-end.
#
# Usage:
#   scripts/ops/dispatch-flatline-detector.sh                 # live run
#   scripts/ops/dispatch-flatline-detector.sh --dry-run       # print only
#   scripts/ops/dispatch-flatline-detector.sh --window-hours 4   # custom window
#
# Environment:
#   CHUMP_DISPATCH_FLATLINE_DISABLED=1   bypass — exit 0 immediately
#   DISPATCH_FLATLINE_WINDOW_HOURS=2     window in hours (default: 2)
#
# Wired to run every 30 min via launchd (see
# scripts/setup/install-dispatch-flatline-detector-launchd.sh; filed as
# follow-up — for now operator can invoke manually or wrap in cron).

set -uo pipefail

if [[ "${CHUMP_DISPATCH_FLATLINE_DISABLED:-0}" == "1" ]]; then
    echo "[dispatch-flatline] CHUMP_DISPATCH_FLATLINE_DISABLED=1 — bypass"
    exit 0
fi

WINDOW_HOURS="${DISPATCH_FLATLINE_WINDOW_HOURS:-2}"
DRY_RUN=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run)        DRY_RUN=1; shift ;;
        --window-hours)   WINDOW_HOURS="$2"; shift 2 ;;
        -h|--help)        sed -n '2,28p' "$0"; exit 0 ;;
        *) echo "unknown arg: $1" >&2; exit 2 ;;
    esac
done

REPO_ROOT="${CHUMP_REPO_ROOT:-/Users/jeffadkins/Projects/Chump}"
AMBIENT="$REPO_ROOT/.chump-locks/ambient.jsonl"

if [[ ! -f "$AMBIENT" ]]; then
    echo "[dispatch-flatline] $AMBIENT not found; nothing to detect" >&2
    exit 0
fi

# Count dispatch events + heartbeat events in the window.
# We use a python one-liner for ISO-8601 time arithmetic — bash date is
# painful enough across BSD/GNU that python is the lower-risk choice here.
COUNTS=$(python3 - "$AMBIENT" "$WINDOW_HOURS" <<'PYEOF'
import json, sys
from datetime import datetime, timezone, timedelta
ambient_path = sys.argv[1]
window_h = float(sys.argv[2])
now = datetime.now(timezone.utc)
since = now - timedelta(hours=window_h)
dispatched = 0
heartbeats = 0
daemon_ticks = 0
with open(ambient_path) as f:
    for line in f:
        try:
            d = json.loads(line)
            ts = datetime.fromisoformat(d['ts'].replace('Z','+00:00'))
            if ts < since:
                continue
            k = d.get('kind', '')
            if k == 'sub_agent_dispatched':
                dispatched += 1
            elif k == 'autopilot_heartbeat':
                heartbeats += 1
            elif k == 'daemon_tick':
                daemon_ticks += 1
        except Exception:
            pass
print(f"{dispatched} {heartbeats} {daemon_ticks}")
PYEOF
)

read -r DISPATCHED HEARTBEATS DAEMON_TICKS <<< "$COUNTS"

echo "[dispatch-flatline] window=${WINDOW_HOURS}h dispatched=$DISPATCHED heartbeats=$HEARTBEATS daemon_ticks=$DAEMON_TICKS"

# Flatline definition:
#   dispatched == 0 AND heartbeats > 0 (we're alive but not dispatching).
# If heartbeats == 0 too, that's a different problem (daemon dead) — caught
# by INFRA-2040 silent-fleet-death watchdog, not this detector.
if [[ "$DISPATCHED" -eq 0 && "$HEARTBEATS" -gt 0 ]]; then
    echo "[dispatch-flatline] FLATLINE: 0 sub-agents dispatched in ${WINDOW_HOURS}h despite $HEARTBEATS autopilot heartbeats"
    if [[ "$DRY_RUN" -eq 1 ]]; then
        echo "[dispatch-flatline] DRY-RUN: would emit kind=dispatch_flatline"
    else
        TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        printf '{"ts":"%s","kind":"dispatch_flatline","window_h":%s,"dispatched":%s,"heartbeats":%s,"daemon_ticks":%s,"note":"autopilot alive but idle — check curator sessions + JIT scheduler dispatch chain"}\n' \
            "$TS" "$WINDOW_HOURS" "$DISPATCHED" "$HEARTBEATS" "$DAEMON_TICKS" \
            >> "$AMBIENT"
        echo "[dispatch-flatline] emitted kind=dispatch_flatline to $AMBIENT"
    fi
    exit 0
fi

if [[ "$DISPATCHED" -gt 0 ]]; then
    echo "[dispatch-flatline] OK: $DISPATCHED dispatched in window — autopilot is shipping"
fi

exit 0
