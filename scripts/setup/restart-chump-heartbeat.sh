#!/usr/bin/env bash
# Restart Chump's self-improve heartbeat on the Mac. Used by Mabel (via SSH) when Chump's
# heartbeat log is stale (>30 min). Exit 0 if restart succeeded and process or log verified;
# exit 1 otherwise so Mabel can notify Jeff.
#
# Runs on the Mac. Usage: run from Chump repo root, or set CHUMP_HOME.
# Env: HEARTBEAT_INTERVAL, HEARTBEAT_DURATION (defaults 8m, 8h if unset).

set -e
ROOT="${CHUMP_HOME:-$(cd "$(dirname "$0")/.." && pwd)}"
cd "$ROOT"
LOG="$ROOT/logs/heartbeat-self-improve.log"
SCRIPT="$ROOT/scripts/dev/heartbeat-self-improve.sh"

if [[ ! -x "$SCRIPT" ]]; then
  echo "restart-chump-heartbeat: script not found or not executable: $SCRIPT" >&2
  exit 1
fi

# Kill existing heartbeat
pkill -f "heartbeat-self-improve.sh" 2>/dev/null || true
sleep 2
if pgrep -f "heartbeat-self-improve.sh" >/dev/null 2>&1; then
  echo "restart-chump-heartbeat: failed to kill existing heartbeat" >&2
  exit 1
fi

# Start with same env Mabel expects (or defaults)
export HEARTBEAT_INTERVAL="${HEARTBEAT_INTERVAL:-8m}"
export HEARTBEAT_DURATION="${HEARTBEAT_DURATION:-8h}"
nohup bash "$SCRIPT" >> "$LOG" 2>&1 &
PID=$!
sleep 3

# Verify: process running and log has a recent line (within last 60s)
if ! kill -0 "$PID" 2>/dev/null; then
  echo "restart-chump-heartbeat: process $PID exited immediately" >&2
  exit 1
fi
if [[ -f "$LOG" ]]; then
  last_line=$(tail -1 "$LOG" 2>/dev/null || true)
  if [[ -z "$last_line" ]] || [[ "$last_line" != *"Heartbeat started"* ]]; then
    # Allow a few seconds for first line to appear
    sleep 5
    last_line=$(tail -1 "$LOG" 2>/dev/null || true)
  fi
  if [[ "$last_line" == *"Heartbeat started"* ]]; then
    echo "restart-chump-heartbeat: ok (pid $PID)"
    exit 0
  fi
fi
echo "restart-chump-heartbeat: started pid $PID but could not verify log" >&2
exit 1
