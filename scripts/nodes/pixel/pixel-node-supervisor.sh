#!/data/data/com.termux/files/usr/bin/bash
# pixel-node-supervisor.sh — RESILIENT-336: keep the Pixel node's long-running
# processes alive (crash-restart), started by the Termux:Boot hook so the node
# self-restores after a reboot or an OOM/phantom-process kill.
#
# Supervised processes:
#   - witness probe   (~/witness/run.sh)  — 5-min helsinki/NATS + trunk watch
#   - pixel worker    (~/pixel-worker.sh) — express-lane gap worker loop
#
# Both are their own infinite loops; this supervisor only respawns the whole
# script when it dies (OOM, Android phantom-process kill, OTA, etc.).
# Termux:Boot runs this on boot; it takes the wake-lock so the loop survives
# Doze. Idempotent: existing live PIDs are left alone.

set -uo pipefail

HOME_DIR="$HOME"
WITNESS_RUN="$HOME_DIR/witness/run.sh"
WORKER_RUN="$HOME_DIR/pixel-worker.sh"
WITNESS_PID="$HOME_DIR/.pixel-witness.pid"
WORKER_PID="$HOME_DIR/.pixel-worker.pid"
ORGANS_RUN="$HOME_DIR/organs/runner.sh"
ORGANS_PID="$HOME_DIR/.pixel-organs.pid"
SUPER_INTERVAL_S="${PIXEL_SUPERVISOR_INTERVAL_S:-60}"

termux-wake-lock 2>/dev/null

is_alive() {
    [ -f "$1" ] && kill -0 "$(cat "$1" 2>/dev/null)" 2>/dev/null
}

start_witness() {
    if [ -x "$WITNESS_RUN" ]; then
        nohup "$WITNESS_RUN" >> "$HOME_DIR/witness/run.err" 2>&1 < /dev/null &
        echo $! > "$WITNESS_PID"
        echo "[supervisor] started witness (pid $(cat "$WITNESS_PID"))"
    fi
}

start_worker() {
    if [ -x "$WORKER_RUN" ]; then
        nohup "$WORKER_RUN" >> "$HOME_DIR/pixel-worker.log" 2>&1 < /dev/null &
        echo $! > "$WORKER_PID"
        echo "[supervisor] started worker (pid $(cat "$WORKER_PID"))"
    fi
}

start_organs() {
    if [ -x "$ORGANS_RUN" ]; then
        nohup "$ORGANS_RUN" >> "$HOME_DIR/organs/organs.log" 2>&1 < /dev/null &
        echo $! > "$ORGANS_PID"
        echo "[supervisor] started organs (pid $(cat "$ORGANS_PID"))"
    fi
}


echo "[supervisor] up — supervising witness + worker every ${SUPER_INTERVAL_S}s"

while true; do
    is_alive "$WITNESS_PID" || start_witness
    is_alive "$WORKER_PID" || start_worker
    is_alive "$ORGANS_PID" || start_organs
    sleep "$SUPER_INTERVAL_S"
done
