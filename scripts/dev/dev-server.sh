#!/usr/bin/env bash
# dev-server.sh — lightweight Chump web server lifecycle for agent UI verification
#
# Agents doing UI/frontend changes must start the dev server, verify their changes
# work, and stop the server when done. This script is the canonical way to do that.
# It is intentionally lighter than restart-chump-web.sh: no git pull, no release
# build by default, no vLLM/MLX startup — just spin up, verify, shut down.
#
# Usage:
#   scripts/dev/dev-server.sh start [--port N] [--build] [--timeout N]
#   scripts/dev/dev-server.sh stop  [--port N]
#   scripts/dev/dev-server.sh status [--port N]
#   scripts/dev/dev-server.sh verify [--port N] [PATH ...]
#   scripts/dev/dev-server.sh restart [--port N] [--build] [--timeout N]
#
# Subcommands:
#   start   — start chump --web in background; waits until /api/health responds
#   stop    — gracefully SIGTERM the tracked pid, SIGKILL after 5 s if needed
#   status  — print running/stopped + URL; exit 0 if running, 1 if stopped
#   verify  — GET each PATH (default: /api/health /v2/) and assert HTTP 200
#             exits 0 if all pass, 1 if any fail (prints pass/FAIL per path)
#   restart — stop (if running), then start
#
# Flags:
#   --port N    web server port (default: 3737; different from prod 3000 so agents
#               can verify without stomping the operator's live server)
#   --build     run `cargo build --bin chump` before starting (default: use pre-built)
#   --timeout N seconds to wait for server to become healthy (default: 60)
#
# PID tracking:
#   /tmp/chump-dev-server-<port>.pid
#   /tmp/chump-dev-server-<port>.log
#
# Exit codes:
#   0  success
#   1  server not running (status/verify) or verify failures
#   2  start failed (build error or timeout)
#   3  port already bound by a non-chump process

set -euo pipefail

REPO_ROOT="$(git -C "$(dirname "$0")" rev-parse --show-toplevel)"
cd "$REPO_ROOT"

# ── Defaults ──────────────────────────────────────────────────────────────────
PORT=3737
DO_BUILD=0
TIMEOUT_S=60
SUBCOMMAND="${1:-help}"
[[ $# -gt 0 ]] && shift

# ── Parse flags ───────────────────────────────────────────────────────────────
EXTRA_PATHS=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --port)    PORT="$2";    shift 2 ;;
        --build)   DO_BUILD=1;   shift   ;;
        --timeout) TIMEOUT_S="$2"; shift 2 ;;
        -h|--help) SUBCOMMAND=help; shift ;;
        /*)        EXTRA_PATHS+=("$1"); shift ;;  # paths for verify
        *)         EXTRA_PATHS+=("$1"); shift ;;
    esac
done

PID_FILE="/tmp/chump-dev-server-${PORT}.pid"
LOG_FILE="/tmp/chump-dev-server-${PORT}.log"
HEALTH_URL="http://127.0.0.1:${PORT}/api/health"

# ── Helpers ───────────────────────────────────────────────────────────────────
say()  { printf '\033[1;36m[dev-server]\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m[dev-server]\033[0m %s\n' "$*"; }
fail() { printf '\033[1;31m[dev-server]\033[0m %s\n' "$*" >&2; }
die()  { fail "$*"; exit "${2:-1}"; }

pick_binary() {
    if [[ -x "${REPO_ROOT}/target/debug/chump" ]]; then
        echo "${REPO_ROOT}/target/debug/chump"
    elif [[ -x "${REPO_ROOT}/target/release/chump" ]]; then
        echo "${REPO_ROOT}/target/release/chump"
    else
        echo ""
    fi
}

is_running() {
    local pid_file="$1"
    [[ -f "$pid_file" ]] || return 1
    local pid
    pid=$(cat "$pid_file")
    kill -0 "$pid" 2>/dev/null || return 1
    # Confirm it's actually our chump process
    ps -p "$pid" -o command= 2>/dev/null | grep -q "chump" || return 1
    return 0
}

wait_healthy() {
    local deadline=$(( $(date +%s) + TIMEOUT_S ))
    while (( $(date +%s) < deadline )); do
        local code
        code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 2 "$HEALTH_URL" 2>/dev/null || echo "000")
        if [[ "$code" == "200" ]]; then
            return 0
        fi
        sleep 1
    done
    return 1
}

# ── Subcommands ───────────────────────────────────────────────────────────────

cmd_start() {
    # Already running?
    if is_running "$PID_FILE"; then
        local pid
        pid=$(cat "$PID_FILE")
        say "already running (pid ${pid}) on port ${PORT} — use 'stop' first or 'restart'"
        exit 0
    fi

    # Port bound by something else?
    if lsof -i ":${PORT}" -sTCP:LISTEN -t >/dev/null 2>&1; then
        local other_pid
        other_pid=$(lsof -i ":${PORT}" -sTCP:LISTEN -t | head -1)
        local other_cmd
        other_cmd=$(ps -p "$other_pid" -o command= 2>/dev/null | head -c 80 || echo "?")
        die "port ${PORT} already bound by pid ${other_pid} (${other_cmd}) — use a different --port" 3
    fi

    # Optional build
    if [[ "$DO_BUILD" -eq 1 ]]; then
        say "cargo build --bin chump …"
        if ! cargo build --bin chump 2>&1 | tee -a "$LOG_FILE"; then
            die "cargo build failed — see ${LOG_FILE}" 2
        fi
    fi

    local bin
    bin=$(pick_binary)
    if [[ -z "$bin" ]]; then
        say "no pre-built binary found — running cargo build --bin chump …"
        if ! cargo build --bin chump 2>&1 | tee -a "$LOG_FILE"; then
            die "cargo build failed — see ${LOG_FILE}" 2
        fi
        bin=$(pick_binary)
    fi
    [[ -z "$bin" ]] && die "could not locate chump binary after build" 2

    say "starting chump --web --port ${PORT} (log: ${LOG_FILE}) …"
    nohup "$bin" --web --port "$PORT" >>"$LOG_FILE" 2>&1 &
    local pid=$!
    echo "$pid" > "$PID_FILE"
    say "  pid ${pid}"

    say "waiting for /api/health (timeout ${TIMEOUT_S}s) …"
    if wait_healthy; then
        ok "✓ server ready → http://127.0.0.1:${PORT}/v2/"
    else
        fail "server did not respond within ${TIMEOUT_S}s"
        fail "  check log: ${LOG_FILE}"
        kill -TERM "$pid" 2>/dev/null || true
        rm -f "$PID_FILE"
        exit 2
    fi
}

cmd_stop() {
    if ! is_running "$PID_FILE"; then
        say "not running (no pid file or process gone)"
        rm -f "$PID_FILE"
        return 0
    fi

    local pid
    pid=$(cat "$PID_FILE")
    say "stopping pid ${pid} …"
    kill -TERM "$pid" 2>/dev/null || true

    local deadline=$(( $(date +%s) + 5 ))
    while (( $(date +%s) < deadline )); do
        if ! kill -0 "$pid" 2>/dev/null; then
            break
        fi
        sleep 1
    done

    if kill -0 "$pid" 2>/dev/null; then
        say "  SIGKILL after timeout"
        kill -KILL "$pid" 2>/dev/null || true
    fi

    rm -f "$PID_FILE"
    ok "stopped"
}

cmd_status() {
    if is_running "$PID_FILE"; then
        local pid
        pid=$(cat "$PID_FILE")
        local code
        code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 2 "$HEALTH_URL" 2>/dev/null || echo "000")
        if [[ "$code" == "200" ]]; then
            ok "running (pid ${pid}) → http://127.0.0.1:${PORT}/v2/  [health: ${code}]"
        else
            say "running (pid ${pid}) but /api/health returned ${code}"
        fi
        exit 0
    else
        say "stopped"
        rm -f "$PID_FILE" 2>/dev/null || true
        exit 1
    fi
}

cmd_verify() {
    # Default verification paths
    local paths=("/api/health" "/v2/")
    if [[ ${#EXTRA_PATHS[@]} -gt 0 ]]; then
        paths=("${EXTRA_PATHS[@]}")
    fi

    # Ensure server is up
    local code
    code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 2 "$HEALTH_URL" 2>/dev/null || echo "000")
    if [[ "$code" != "200" ]]; then
        die "server not responding on port ${PORT} (/api/health → ${code}); run 'start' first" 1
    fi

    local failures=0
    for path in "${paths[@]}"; do
        local url="http://127.0.0.1:${PORT}${path}"
        local http_code
        http_code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "$url" 2>/dev/null || echo "000")
        if [[ "$http_code" == "200" ]]; then
            ok "  PASS  ${http_code}  ${path}"
        else
            fail "  FAIL  ${http_code}  ${path}"
            (( failures++ )) || true
        fi
    done

    if [[ "$failures" -gt 0 ]]; then
        fail "${failures} path(s) failed"
        exit 1
    fi
    ok "all paths OK"
}

cmd_restart() {
    cmd_stop
    cmd_start
}

cmd_help() {
    sed -n '2,/^set -/p' "$0" | sed 's/^# \?//'
}

# ── Dispatch ──────────────────────────────────────────────────────────────────
case "$SUBCOMMAND" in
    start)   cmd_start   ;;
    stop)    cmd_stop    ;;
    status)  cmd_status  ;;
    verify)  cmd_verify  ;;
    restart) cmd_restart ;;
    help|-h|--help) cmd_help; exit 0 ;;
    *) fail "unknown subcommand: ${SUBCOMMAND}"; cmd_help >&2; exit 1 ;;
esac
