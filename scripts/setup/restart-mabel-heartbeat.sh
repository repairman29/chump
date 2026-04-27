#!/usr/bin/env bash
# Restart Mabel's heartbeat on the Pixel. Invoked by Chump via SSH when Mabel's heartbeat
# log is stale (>30 min). Runs on the Pixel (Termux). Exit 0 if restart succeeded and
# process or log verified; exit 1 otherwise so Chump can notify Jeff.
#
# Usage: from Pixel, run from ~/chump or set CHUMP_HOME. Typically called by Chump:
#   ssh -p 8022 termux 'cd ~/chump && bash scripts/setup/restart-mabel-heartbeat.sh'

set -e
ROOT="${CHUMP_HOME:-$(cd "$(dirname "$0")/../.." && pwd)}"
cd "$ROOT"
LOG="$ROOT/logs/heartbeat-mabel.log"
SCRIPT="$ROOT/scripts/dev/heartbeat-mabel.sh"

if [[ ! -x "$SCRIPT" ]]; then
  echo "restart-mabel-heartbeat: script not found or not executable: $SCRIPT" >&2
  exit 1
fi

# Kill existing Mabel heartbeat (not the bot)
pkill -f "heartbeat-mabel.sh" 2>/dev/null || true
sleep 2
if pgrep -f "heartbeat-mabel.sh" >/dev/null 2>&1; then
  echo "restart-mabel-heartbeat: failed to kill existing heartbeat" >&2
  exit 1
fi

mkdir -p "$ROOT/logs"
nohup bash "$SCRIPT" >> "$LOG" 2>&1 &
PID=$!
sleep 3

# Verify: process running and log has a recent line
if ! kill -0 "$PID" 2>/dev/null; then
  echo "restart-mabel-heartbeat: process $PID exited immediately" >&2
  exit 1
fi
if [[ -f "$LOG" ]]; then
  last_line=$(tail -1 "$LOG" 2>/dev/null || true)
  if [[ -z "$last_line" ]]; then
    sleep 5
    last_line=$(tail -1 "$LOG" 2>/dev/null || true)
  fi
  if [[ "$last_line" == *"Heartbeat started"* ]] || [[ "$last_line" == *"Preflight"* ]] || [[ "$last_line" == *"Round"* ]]; then
    echo "restart-mabel-heartbeat: ok (pid $PID)"
    exit 0
  fi
fi
echo "restart-mabel-heartbeat: started pid $PID but could not verify log" >&2
exit 1
