#!/usr/bin/env bash
# coord-serve.sh — Start the local NATS server for multi-agent coordination.
#
# Phase 1 of ADR-004: NATS runs as a local daemon on this machine.
# All chump-coord operations connect to nats://127.0.0.1:4222.
#
# Usage:
#   scripts/coord-serve.sh          # start NATS (idempotent — no-op if running)
#   scripts/coord-serve.sh --stop   # stop NATS
#   scripts/coord-serve.sh --status # show status
#   scripts/coord-serve.sh --init   # init buckets/streams only (NATS already running)
#
# Install nats-server:
#   brew install nats-server                    (macOS)
#   curl -L https://github.com/nats-io/nats-server/releases/latest/download/nats-server-v2.10.x-linux-amd64.zip
#   go install github.com/nats-io/nats-server/v2@latest
#
# Install nats CLI (for manual inspection):
#   brew install nats-io/nats-tools/nats

set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
LOCK_DIR="$REPO_ROOT/.chump-locks"
PID_FILE="$LOCK_DIR/.nats-server.pid"
LOG_FILE="$LOCK_DIR/.nats-server.log"
NATS_PORT="${CHUMP_NATS_PORT:-4222}"
COORD_BIN="$(command -v chump-coord 2>/dev/null || echo "")"

# ── Helpers ───────────────────────────────────────────────────────────────────
bold()  { printf '\033[1m%s\033[0m' "$*"; }
green() { printf '\033[0;32m%s\033[0m' "$*"; }
red()   { printf '\033[0;31m%s\033[0m' "$*"; }
dim()   { printf '\033[2m%s\033[0m' "$*"; }

server_running() {
    [[ -f "$PID_FILE" ]] || return 1
    local pid
    pid="$(cat "$PID_FILE" 2>/dev/null)" || return 1
    kill -0 "$pid" 2>/dev/null
}

# ── Commands ──────────────────────────────────────────────────────────────────
case "${1:---start}" in

    --stop)
        if server_running; then
            pid="$(cat "$PID_FILE")"
            kill "$pid" 2>/dev/null && rm -f "$PID_FILE"
            printf '%s NATS server stopped (pid=%s)\n' "$(red '■')" "$pid"
        else
            printf '%s NATS server not running\n' "$(dim '·')"
        fi
        exit 0
        ;;

    --status)
        if server_running; then
            pid="$(cat "$PID_FILE")"
            printf '%s NATS server running  pid=%-6s  port=%s\n' "$(green '●')" "$pid" "$NATS_PORT"
            if [[ -n "$COORD_BIN" ]]; then
                "$COORD_BIN" status 2>/dev/null || true
            fi
        else
            printf '%s NATS server not running\n' "$(dim '●')"
        fi
        exit 0
        ;;

    --init)
        # Initialise KV buckets + JetStream stream without starting the server.
        # Useful after a manual nats-server start.
        if [[ -z "$COORD_BIN" ]]; then
            printf '%s chump-coord binary not found — run: cargo build -p chump-coord\n' "$(red '✗')"
            exit 1
        fi
        printf 'Initialising chump-coord KV + JetStream… '
        if "$COORD_BIN" ping >/dev/null 2>&1; then
            # ping triggers connect() which creates buckets/streams
            "$COORD_BIN" status >/dev/null 2>&1
            printf '%s\n' "$(green 'done')"
        else
            printf '%s NATS server not reachable at localhost:%s\n' "$(red '✗')" "$NATS_PORT"
            exit 1
        fi
        exit 0
        ;;

    --start|*)
        ;;
esac

# ── Start ─────────────────────────────────────────────────────────────────────
if server_running; then
    pid="$(cat "$PID_FILE")"
    printf '%s NATS server already running (pid=%s, port=%s)\n' "$(green '●')" "$pid" "$NATS_PORT"
    exit 0
fi

# Check nats-server binary
if ! command -v nats-server >/dev/null 2>&1; then
    printf '%s nats-server not found.\n' "$(red '✗')" >&2
    printf '  macOS:  brew install nats-server\n' >&2
    printf '  Linux:  https://github.com/nats-io/nats-server/releases\n' >&2
    printf '  Go:     go install github.com/nats-io/nats-server/v2@latest\n' >&2
    exit 1
fi

mkdir -p "$LOCK_DIR"

# Start with JetStream enabled, log to file, PID to file
nats-server \
    --port "$NATS_PORT" \
    --jetstream \
    --store_dir "$LOCK_DIR/.nats-store" \
    --pid "$PID_FILE" \
    --log "$LOG_FILE" \
    --daemonize \
    2>/dev/null

# Wait up to 3s for it to be reachable
for i in 1 2 3; do
    sleep 1
    if server_running; then break; fi
done

if server_running; then
    pid="$(cat "$PID_FILE")"
    printf '%s NATS server started  pid=%-6s  port=%s\n' "$(green '●')" "$pid" "$NATS_PORT"
    printf '  log: %s\n' "$(dim "$LOG_FILE")"

    # Initialise KV buckets + JetStream stream via chump-coord ping
    if [[ -n "$COORD_BIN" ]]; then
        sleep 0.5
        "$COORD_BIN" ping >/dev/null 2>&1 && \
            printf '%s chump-coord KV + JetStream initialised\n' "$(green '✓')" || \
            printf '%s chump-coord ping failed — run: scripts/coord-serve.sh --init\n' "$(dim '!')"
    else
        printf '%s chump-coord binary not found — build with: cargo build -p chump-coord\n' "$(dim '!')"
    fi
else
    printf '%s NATS server failed to start — check log: %s\n' "$(red '✗')" "$LOG_FILE" >&2
    exit 1
fi
