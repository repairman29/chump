#!/usr/bin/env bash
# restart-chump-web.sh — INFRA-179 (2026-05-01)
#
# One-command kill + rebuild + relaunch of the local Chump PWA server.
#
# Why: shipped fixes to the agent loop / streaming provider / web server
# don't take effect until the running binary is replaced. Manual
# `pkill chump && cargo build && ./target/release/chump --web ...` works
# but is finger-stumbling and easy to forget the rebuild step. This
# script does it atomically with sane defaults + log capture.
#
# Usage:
#   scripts/dev/restart-chump-web.sh                  # default: port 3000, release build, foreground logs
#   scripts/dev/restart-chump-web.sh --port 3001      # override port
#   scripts/dev/restart-chump-web.sh --skip-build     # don't rebuild — useful when you just want to bounce
#   scripts/dev/restart-chump-web.sh --skip-pull      # don't `git pull origin main` first
#   scripts/dev/restart-chump-web.sh --foreground     # tail logs in foreground (default backgrounds + writes log)
#
# Environment:
#   CHUMP_RESTART_LOG    log file (default: /tmp/chump-web-$(date +%s).log)
#   RUST_LOG             passed through to chump
#
# Exit codes:
#   0  server restarted, PWA responding on the port
#   1  build failed
#   2  server failed to come up within timeout
#   3  port still bound after kill (something else holding it)

set -euo pipefail

PORT=3000
SKIP_BUILD=0
SKIP_PULL=0
FOREGROUND=0
TIMEOUT_S=60

while [[ $# -gt 0 ]]; do
    case "$1" in
        --port)        PORT="$2"; shift 2 ;;
        --skip-build)  SKIP_BUILD=1; shift ;;
        --skip-pull)   SKIP_PULL=1; shift ;;
        --foreground)  FOREGROUND=1; shift ;;
        --timeout)     TIMEOUT_S="$2"; shift 2 ;;
        -h|--help)
            sed -n '2,/^$/p' "$0" | sed 's/^# \?//'
            exit 0 ;;
        *) echo "unknown arg: $1" >&2; exit 2 ;;
    esac
done

REPO_ROOT="$(git -C "$(dirname "$0")" rev-parse --show-toplevel)"
cd "$REPO_ROOT"

LOG="${CHUMP_RESTART_LOG:-/tmp/chump-web-$(date +%s).log}"
URL="http://localhost:${PORT}/v2/"

say()  { printf '\033[1;36m[restart-chump-web]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[restart-chump-web]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[restart-chump-web]\033[0m %s\n' "$*" >&2; exit "${2:-1}"; }

# ── 1. Find + kill any existing chump --web on the target port ──────────────
say "Looking for chump --web on port ${PORT}…"
PIDS=$(pgrep -f "chump.*--web.*--port ${PORT}" 2>/dev/null || true)
# Also catch the default-port case (no explicit --port flag)
if [[ "${PORT}" == "3000" ]]; then
    DEFAULT_PIDS=$(pgrep -f "chump --web( |$)" 2>/dev/null | while read -r p; do
        cmdline=$(ps -p "$p" -o command= 2>/dev/null || true)
        # Default-port if no --port arg present
        if ! echo "$cmdline" | grep -q -- '--port'; then
            echo "$p"
        fi
    done || true)
    PIDS="${PIDS}
${DEFAULT_PIDS}"
fi
PIDS=$(echo "$PIDS" | sort -u | grep -v '^$' || true)

if [[ -n "$PIDS" ]]; then
    for pid in $PIDS; do
        say "  killing pid ${pid} ($(ps -p $pid -o command= 2>/dev/null | head -c 80))"
        kill -TERM "$pid" 2>/dev/null || true
    done
    # Give it 3s to shut down cleanly, then SIGKILL stragglers
    sleep 3
    for pid in $PIDS; do
        if kill -0 "$pid" 2>/dev/null; then
            warn "  pid ${pid} did not exit on SIGTERM; SIGKILL"
            kill -KILL "$pid" 2>/dev/null || true
        fi
    done
else
    say "  no existing chump --web process on port ${PORT}"
fi

# ── 2. Confirm the port is free ─────────────────────────────────────────────
if lsof -i ":${PORT}" -sTCP:LISTEN -t >/dev/null 2>&1; then
    OTHER_PID=$(lsof -i ":${PORT}" -sTCP:LISTEN -t | head -1)
    OTHER_CMD=$(ps -p "$OTHER_PID" -o command= 2>/dev/null | head -c 80)
    die "port ${PORT} still bound by pid ${OTHER_PID} (${OTHER_CMD}) — not chump; refusing to kill blindly" 3
fi

# ── 3. Pull latest main (unless --skip-pull) ────────────────────────────────
if [[ "$SKIP_PULL" -eq 0 ]]; then
    say "git pull origin main…"
    if ! git pull --rebase --autostash origin main >>"$LOG" 2>&1; then
        warn "git pull failed — continuing with current HEAD (see $LOG)"
    fi
fi

# ── 4. Rebuild (unless --skip-build) ────────────────────────────────────────
if [[ "$SKIP_BUILD" -eq 0 ]]; then
    BUILD_START=$(date +%s)
    say "cargo build --release --bin chump… (logging to $LOG)"
    if ! cargo build --release --bin chump >>"$LOG" 2>&1; then
        die "cargo build failed — see $LOG" 1
    fi
    BUILD_END=$(date +%s)
    say "  built in $((BUILD_END - BUILD_START))s"
fi

# ── 5. Relaunch ─────────────────────────────────────────────────────────────
BIN="${REPO_ROOT}/target/release/chump"
[[ -x "$BIN" ]] || die "binary not found at $BIN — run without --skip-build" 1

say "Starting chump --web --port ${PORT}…"
if [[ "$FOREGROUND" -eq 1 ]]; then
    exec "$BIN" --web --port "$PORT"
else
    nohup "$BIN" --web --port "$PORT" >>"$LOG" 2>&1 &
    NEW_PID=$!
    say "  pid ${NEW_PID}, log ${LOG}"
fi

# ── 6. Wait for the PWA to come up ──────────────────────────────────────────
say "Waiting for ${URL} to respond (timeout ${TIMEOUT_S}s)…"
DEADLINE=$(($(date +%s) + TIMEOUT_S))
while (( $(date +%s) < DEADLINE )); do
    if curl -sf --max-time 2 "$URL" -o /dev/null 2>/dev/null; then
        ELAPSED=$(($(date +%s) - DEADLINE + TIMEOUT_S))
        say "✓ PWA responding in ${ELAPSED}s"
        say "  open: ${URL}"
        say "  log:  ${LOG}"
        exit 0
    fi
    sleep 1
done

die "PWA did not respond within ${TIMEOUT_S}s — check ${LOG}" 2
