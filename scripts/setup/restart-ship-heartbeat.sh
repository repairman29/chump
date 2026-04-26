#!/usr/bin/env bash
# Restart the ship heartbeat on the Mac. Used by Mabel (via SSH) when progress-based
# monitoring detects the ship round stuck (same round/status for > MABEL_FARMER_STUCK_MINUTES).
# Exit 0 if restart succeeded and process or log verified; exit 1 otherwise.
#
# Runs on the Mac. Usage: run from Chump repo root, or set CHUMP_HOME.

set -e
ROOT="${CHUMP_HOME:-$(cd "$(dirname "$0")/../.." && pwd)}"
cd "$ROOT"
LOG="$ROOT/logs/heartbeat-ship.log"
SCRIPT="$ROOT/scripts/dev/heartbeat-ship.sh"

if [[ ! -x "$SCRIPT" ]]; then
  echo "restart-ship-heartbeat: script not found or not executable: $SCRIPT" >&2
  exit 1
fi

# Kill existing ship heartbeat
pkill -f "heartbeat-ship.sh" 2>/dev/null || true
sleep 2
if pgrep -f "heartbeat-ship.sh" >/dev/null 2>&1; then
  echo "restart-ship-heartbeat: failed to kill existing heartbeat" >&2
  exit 1
fi

nohup bash "$SCRIPT" >> "$LOG" 2>&1 &
PID=$!
sleep 3

# Verify: process running and log has a recent line
if ! kill -0 "$PID" 2>/dev/null; then
  echo "restart-ship-heartbeat: process $PID exited immediately" >&2
  exit 1
fi
if [[ -f "$LOG" ]]; then
  last_line=$(tail -1 "$LOG" 2>/dev/null || true)
  if [[ -z "$last_line" ]] || [[ "$last_line" != *"Ship heartbeat started"* ]]; then
    sleep 5
    last_line=$(tail -1 "$LOG" 2>/dev/null || true)
  fi
  if [[ "$last_line" == *"Ship heartbeat started"* ]]; then
    echo "restart-ship-heartbeat: ok (pid $PID)"
    exit 0
  fi
fi
echo "restart-ship-heartbeat: started pid $PID but could not verify log" >&2
exit 1
