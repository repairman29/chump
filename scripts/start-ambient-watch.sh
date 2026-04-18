#!/usr/bin/env bash
# start-ambient-watch.sh — start the anomaly detector daemon and record its PID.
#
# Idempotent: if the daemon is already running (PID file exists + process alive),
# prints a message and exits 0 without starting a second copy.
#
# Usage:
#   scripts/start-ambient-watch.sh           # start in background
#   scripts/start-ambient-watch.sh --stop    # stop the running daemon

set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
LOCK_DIR="$REPO_ROOT/.chump-locks"
mkdir -p "$LOCK_DIR"
PID_FILE="$LOCK_DIR/ambient-watch.pid"
LOG_FILE="$LOCK_DIR/ambient-watch.log"

if [[ "${1:-}" == "--stop" ]]; then
    if [[ -f "$PID_FILE" ]]; then
        PID="$(cat "$PID_FILE")"
        if kill -0 "$PID" 2>/dev/null; then
            kill "$PID"
            rm -f "$PID_FILE"
            echo "[ambient-watch] stopped (pid=$PID)"
        else
            echo "[ambient-watch] not running (stale pid=$PID)" >&2
            rm -f "$PID_FILE"
        fi
    else
        echo "[ambient-watch] not running (no pid file)" >&2
    fi
    exit 0
fi

# Check if already running
if [[ -f "$PID_FILE" ]]; then
    PID="$(cat "$PID_FILE")"
    if kill -0 "$PID" 2>/dev/null; then
        echo "[ambient-watch] already running (pid=$PID)"
        exit 0
    else
        rm -f "$PID_FILE"
    fi
fi

# Start daemon
"$REPO_ROOT/scripts/ambient-watch.sh" >> "$LOG_FILE" 2>&1 &
echo $! > "$PID_FILE"
echo "[ambient-watch] started (pid=$(cat "$PID_FILE"), log=$LOG_FILE)"
