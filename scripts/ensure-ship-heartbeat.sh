#!/usr/bin/env bash
# Ensure the ship heartbeat is running on the Mac. Clears stale lock (e.g. from a
# one-off test or Cursor sandbox) and starts heartbeat-ship.sh if not running.
# Used by Mabel (via SSH) during patrol so she can detect and fix ship heartbeat issues.
#
# Runs on the Mac. Usage: run from Chump repo root, or set CHUMP_HOME.
# Exit 0 if ship is or was started and log verified; exit 1 otherwise.

set -e
ROOT="${CHUMP_HOME:-$(cd "$(dirname "$0")/.." && pwd)}"
cd "$ROOT"
LOCK="$ROOT/logs/heartbeat-ship.lock"
LOG="$ROOT/logs/heartbeat-ship.log"
SCRIPT="$ROOT/scripts/heartbeat-ship.sh"
mkdir -p "$ROOT/logs"

if [[ ! -x "$SCRIPT" ]]; then
  echo "ensure-ship-heartbeat: script not found or not executable: $SCRIPT" >&2
  exit 1
fi

# Clear stale lock: lock pid not running, or process is not the real 8h loop (e.g. "source ..." or one-round test).
if [[ -f "$LOCK" ]]; then
  lock_pid=$(cat "$LOCK" 2>/dev/null || true)
  if [[ -n "$lock_pid" ]] && kill -0 "$lock_pid" 2>/dev/null; then
    cmd=$(ps -p "$lock_pid" -o command= 2>/dev/null || true)
    # Real loop is "bash .../heartbeat-ship.sh" (no "source", not one-round).
    if [[ -n "$cmd" ]] && [[ "$cmd" == *"heartbeat-ship"* ]] && [[ "$cmd" != *"source"* ]] && [[ "$cmd" != *"ONE_ROUND"* ]]; then
      echo "ensure-ship-heartbeat: ship already running (pid $lock_pid)"
      exit 0
    fi
  fi
  rm -f "$LOCK"
fi

# Check for a real ship process (in case lock was removed but process still running).
for pid in $(pgrep -f "heartbeat-ship.sh" 2>/dev/null || true); do
  cmd=$(ps -p "$pid" -o command= 2>/dev/null || true)
  if [[ -n "$cmd" ]] && [[ "$cmd" == *"heartbeat-ship"* ]] && [[ "$cmd" != *"source"* ]] && [[ "$cmd" != *"ONE_ROUND"* ]]; then
    echo "ensure-ship-heartbeat: ship already running (pid $pid)"
    exit 0
  fi
done

# Start ship heartbeat (load .env like the script does).
[[ -f "$ROOT/.env" ]] && set -a && source "$ROOT/.env" && set +a
nohup bash "$SCRIPT" >> "$LOG" 2>&1 &
PID=$!
sleep 4

if ! kill -0 "$PID" 2>/dev/null; then
  echo "ensure-ship-heartbeat: process $PID exited immediately" >&2
  exit 1
fi
# Ship script prints cascade status first, then "Ship heartbeat started"; allow a few seconds.
for _ in 1 2 3 4 5; do
  if [[ -f "$LOG" ]] && grep -q "Ship heartbeat started" "$LOG" 2>/dev/null; then
    echo "ensure-ship-heartbeat: ok (started pid $PID)"
    exit 0
  fi
  sleep 3
done
echo "ensure-ship-heartbeat: started pid $PID but could not verify log" >&2
exit 1
