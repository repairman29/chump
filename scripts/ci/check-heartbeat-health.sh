#!/usr/bin/env bash
# Check heartbeat health: count recent ok vs exit non-zero and suggest interval adjustments.
# Run every 20m (cron or launchd) to monitor until peak performance; adjust HEARTBEAT_INTERVAL based on output.
#
# Usage:
#   ./scripts/ci/check-heartbeat-health.sh              # print summary to stdout
#   ./scripts/ci/check-heartbeat-health.sh >> logs/heartbeat-health.log 2>&1   # append (e.g. from launchd)

set -e
ROOT="${CHUMP_HOME:-$(cd "$(dirname "$0")/../.." && pwd)}"
cd "$ROOT"
LOG_DIR="${ROOT}/logs"
SELF_LOG="${LOG_DIR}/heartbeat-self-improve.log"
CURSOR_LOG="${LOG_DIR}/heartbeat-cursor-improve-loop.log"
SHIP_LOG="${LOG_DIR}/heartbeat-ship.log"
LEARN_LOG="${LOG_DIR}/heartbeat-learn.log"

# Look at last 20 minutes of rounds. Use last 80 lines to capture round lines.
TAIL_LINES="${TAIL_LINES:-80}"
[[ "$TAIL_LINES" =~ ^[0-9]+$ ]] || TAIL_LINES=80
now=$(date -u +%Y-%m-%dT%H:%M:%SZ)

report() {
  echo "[$now] $1"
}

# Only count a log if it was updated within the last 2 hours (active heartbeat).
ACTIVE_WINDOW_SECS=7200
log_is_active() {
  [[ -f "$1" ]] || return 1
  local mtime now
  mtime=$(date -r "$1" +%s 2>/dev/null) || return 1
  now=$(date +%s)
  [[ $((now - mtime)) -lt $ACTIVE_WINDOW_SECS ]]
}
count_ok()   { if log_is_active "$1"; then tail -n "$TAIL_LINES" "$1" | grep -c "Round.* ok$" 2>/dev/null || true; else echo 0; fi; }
count_fail() { if log_is_active "$1"; then tail -n "$TAIL_LINES" "$1" | grep -c "Round.*exit non-zero" 2>/dev/null || true; else echo 0; fi; }

# --- Self-improve
self_ok=$(count_ok "$SELF_LOG")
self_fail=$(count_fail "$SELF_LOG")

# --- Cursor-improve loop
cursor_ok=$(count_ok "$CURSOR_LOG")
cursor_fail=$(count_fail "$CURSOR_LOG")

# --- Ship heartbeat
ship_ok=$(count_ok "$SHIP_LOG")
ship_fail=$(count_fail "$SHIP_LOG")

# --- Learn heartbeat
learn_ok=$(count_ok "$LEARN_LOG")
learn_fail=$(count_fail "$LEARN_LOG")

total_ok=$((self_ok + cursor_ok + ship_ok + learn_ok))
total_fail=$((self_fail + cursor_fail + ship_fail + learn_fail))
total=$((total_ok + total_fail))

# Which heartbeats are actually running (process check)?
running=""
pgrep -fl "heartbeat-self-improve" | grep -qv grep 2>/dev/null && running="${running} self_improve"
pgrep -fl "heartbeat-cursor-improve" | grep -qv grep 2>/dev/null && running="${running} cursor_improve"
pgrep -fl "heartbeat-ship" | grep -qv grep 2>/dev/null && running="${running} ship"
pgrep -fl "heartbeat-learn" | grep -qv grep 2>/dev/null && running="${running} learn"
running="${running# }"
[[ -z "$running" ]] && running="none"

report "heartbeat-health: running=[$running] | self_improve ok=$self_ok fail=$self_fail | cursor_improve ok=$cursor_ok fail=$cursor_fail | ship ok=$ship_ok fail=$ship_fail | learn ok=$learn_ok fail=$learn_fail | total ok=$total_ok fail=$total_fail"

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
