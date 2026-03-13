#!/usr/bin/env bash
# Check heartbeat health: count recent ok vs exit non-zero and suggest interval adjustments.
# Run every 20m (cron or launchd) to monitor until peak performance; adjust HEARTBEAT_INTERVAL based on output.
#
# Usage:
#   ./scripts/check-heartbeat-health.sh              # print summary to stdout
#   ./scripts/check-heartbeat-health.sh >> logs/heartbeat-health.log 2>&1   # append (e.g. from launchd)

set -e
ROOT="${CHUMP_HOME:-$(cd "$(dirname "$0")/.." && pwd)}"
cd "$ROOT"
LOG_DIR="${ROOT}/logs"
SELF_LOG="${LOG_DIR}/heartbeat-self-improve.log"
CURSOR_LOG="${LOG_DIR}/heartbeat-cursor-improve-loop.log"

# Look at last 20 minutes of rounds: ~2–3 at 8m, ~4 at 5m (self); ~4 at 5m (cursor). Use last 80 lines to capture round lines.
TAIL_LINES="${TAIL_LINES:-80}"
[[ "$TAIL_LINES" =~ ^[0-9]+$ ]] || TAIL_LINES=80
now=$(date -u +%Y-%m-%dT%H:%M:%SZ)

report() {
  echo "[$now] $1"
}

# --- Self-improve
self_ok=0
self_fail=0
if [[ -f "$SELF_LOG" ]]; then
  self_ok=$(tail -n "$TAIL_LINES" "$SELF_LOG" | grep -c "Round.*: ok" 2>/dev/null) || self_ok=0
  self_fail=$(tail -n "$TAIL_LINES" "$SELF_LOG" | grep -c "Round.*: exit non-zero" 2>/dev/null) || self_fail=0
fi

# --- Cursor-improve loop
cursor_ok=0
cursor_fail=0
if [[ -f "$CURSOR_LOG" ]]; then
  cursor_ok=$(tail -n "$TAIL_LINES" "$CURSOR_LOG" | grep -c "Round.*: ok" 2>/dev/null) || cursor_ok=0
  cursor_fail=$(tail -n "$TAIL_LINES" "$CURSOR_LOG" | grep -c "Round.*: exit non-zero" 2>/dev/null) || cursor_fail=0
fi

total_ok=$((self_ok + cursor_ok))
total_fail=$((self_fail + cursor_fail))
total=$((total_ok + total_fail))

report "heartbeat-health: self_improve ok=$self_ok fail=$self_fail | cursor_improve ok=$cursor_ok fail=$cursor_fail | total ok=$total_ok fail=$total_fail"

if [[ $total -eq 0 ]]; then
  report "heartbeat-health: no recent rounds in last ~${TAIL_LINES} log lines. Start heartbeat or cursor-improve loop if you want to reach peak."
  exit 0
fi

# Simple rate: fail ratio
if [[ $total_fail -ge $total_ok ]] && [[ $total_fail -gt 0 ]]; then
  report "heartbeat-health: RECOMMEND back off — many rounds failing. Try HEARTBEAT_INTERVAL=10m (self-improve) or 8m (cursor-improve), then re-check in 20m."
elif [[ $total_fail -gt 0 ]]; then
  report "heartbeat-health: some failures; current interval is likely near limit. Hold or try one step lower (5m/3m) and re-check."
else
  report "heartbeat-health: all recent rounds ok — you can try HEARTBEAT_INTERVAL=5m (self-improve) or 3m (cursor-improve) to top out; re-check in 20m."
fi
exit 0
