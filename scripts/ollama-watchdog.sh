#!/usr/bin/env bash
# ollama-watchdog.sh — REL-002 mitigation: detect the Ollama 0.20.7 crash
# signature before it kills the user's session, and either auto-restart
# (default) or page (CHUMP_OLLAMA_WATCHDOG_NOTIFY=1).
#
# REL-002 is upstream-blocked (Ollama segfault under sustained load on
# 24GB M4) — until the upstream fix lands, this is the workaround. Three
# detection signals, any of which trips the action:
#
#   1. /api/tags returns 5xx OR no response for >timeout seconds
#   2. ollama.log contains a "panic:" / "SIGSEGV" / "fatal error" line
#      written in the last DETECT_WINDOW_SEC seconds
#   3. Process is alive but model API consistently times out
#
# Usage:
#   scripts/ollama-watchdog.sh                      # one-shot check
#   scripts/ollama-watchdog.sh --loop               # daemon mode, 30s tick
#   scripts/ollama-watchdog.sh --loop --no-restart  # detect-only (paging)
#   scripts/ollama-watchdog.sh --help
#
# Env:
#   CHUMP_OLLAMA_BASE          default http://127.0.0.1:11434
#   CHUMP_OLLAMA_LOG_PATH      default $HOME/.ollama/logs/server.log
#   CHUMP_OLLAMA_HEALTH_TIMEOUT default 5 (seconds)
#   CHUMP_OLLAMA_TICK_SEC      default 30 (loop mode)
#   CHUMP_OLLAMA_DETECT_WINDOW_SEC  default 120 (log scan window)
#   CHUMP_OLLAMA_RESTART_CMD   default "ollama serve" (foreground)
#   CHUMP_OLLAMA_WATCHDOG_NOTIFY  set to 1 to also write to chump notify_tool

set -uo pipefail  # not -e — we want to keep looping even on transient errors

BASE="${CHUMP_OLLAMA_BASE:-http://127.0.0.1:11434}"
LOG_PATH="${CHUMP_OLLAMA_LOG_PATH:-$HOME/.ollama/logs/server.log}"
HEALTH_TIMEOUT="${CHUMP_OLLAMA_HEALTH_TIMEOUT:-5}"
TICK_SEC="${CHUMP_OLLAMA_TICK_SEC:-30}"
DETECT_WINDOW="${CHUMP_OLLAMA_DETECT_WINDOW_SEC:-120}"
RESTART_CMD="${CHUMP_OLLAMA_RESTART_CMD:-ollama serve}"

LOOP=0
NO_RESTART=0
NOTIFY="${CHUMP_OLLAMA_WATCHDOG_NOTIFY:-0}"
for arg in "$@"; do
  case "$arg" in
    --loop) LOOP=1 ;;
    --no-restart) NO_RESTART=1 ;;
    --notify) NOTIFY=1 ;;
    --help|-h) sed -n '2,30p' "$0"; exit 0 ;;
    *) echo "unknown flag: $arg" >&2; exit 2 ;;
  esac
done

# Health check: returns 0 if ollama answers /api/tags within HEALTH_TIMEOUT.
check_api_health() {
  curl -sf --connect-timeout "$HEALTH_TIMEOUT" --max-time "$HEALTH_TIMEOUT" \
    "$BASE/api/tags" >/dev/null 2>&1
}

# Process check: any ollama serve process alive?
check_process_alive() {
  pgrep -f "ollama serve" >/dev/null 2>&1 \
    || pgrep -f "/ollama/bin/ollama" >/dev/null 2>&1
}

# Log scan: look for crash markers in the last DETECT_WINDOW seconds.
# Returns 0 if a marker was found.
check_log_for_crash() {
  [[ -f "$LOG_PATH" ]] || return 1
  local now_epoch since_epoch
  now_epoch=$(date -u +%s)
  since_epoch=$((now_epoch - DETECT_WINDOW))
  # Linux stat -c, macOS stat -f. We tail the last 500 lines as a fallback
  # since Ollama log doesn't always have a parseable timestamp on every line.
  if tail -n 500 "$LOG_PATH" 2>/dev/null | grep -qE "panic:|SIGSEGV|fatal error:|out of memory|llama_decode failed|signal: killed"; then
    return 0
  fi
  return 1
}

# Restart action: kill any live ollama process, then re-launch in background.
restart_ollama() {
  echo "[watchdog] $(date -u +%H:%M:%S) restarting ollama..." >&2
  # Try graceful kill first
  pkill -TERM -f "ollama serve" 2>/dev/null
  sleep 2
  # Hard kill if still alive
  pkill -KILL -f "ollama serve" 2>/dev/null
  sleep 1
  # Relaunch detached
  nohup $RESTART_CMD >/dev/null 2>&1 &
  echo "[watchdog] restart command spawned (PID $!)" >&2
  # Verify
  sleep 5
  if check_api_health; then
    echo "[watchdog] ollama healthy after restart" >&2
    return 0
  else
    echo "[watchdog] WARN: ollama still unhealthy 5s after restart" >&2
    return 1
  fi
}

notify_jeff() {
  local msg="$1"
  if [[ "$NOTIFY" = "1" ]]; then
    # Try chump notify if available — non-blocking.
    if command -v chump >/dev/null 2>&1; then
      chump --notify "ollama watchdog: $msg" 2>/dev/null || true
    fi
    # Always log to stderr.
    echo "[watchdog] NOTIFY: $msg" >&2
  fi
}

# Single tick: returns 0 if all healthy, 1 if action taken (or would have been).
do_one_tick() {
  local needs_action=0
  local reason=""

  if ! check_process_alive; then
    needs_action=1
    reason="process not running"
  elif ! check_api_health; then
    needs_action=1
    reason="API health check failed (timeout ${HEALTH_TIMEOUT}s)"
  elif check_log_for_crash; then
    needs_action=1
    reason="crash marker in $LOG_PATH (last ${DETECT_WINDOW}s)"
  fi

  if [[ $needs_action -eq 1 ]]; then
    notify_jeff "$reason"
    if [[ $NO_RESTART -eq 1 ]]; then
      echo "[watchdog] $(date -u +%H:%M:%S) DETECT-ONLY: $reason" >&2
      return 1
    fi
    restart_ollama || return 1
    return 1  # action was taken; tick "failed" in the sense that recovery happened
  fi

  return 0
}

if [[ $LOOP -eq 1 ]]; then
  echo "[watchdog] starting loop: tick=${TICK_SEC}s base=$BASE log=$LOG_PATH no_restart=$NO_RESTART"
  while true; do
    do_one_tick || true
    sleep "$TICK_SEC"
  done
else
  do_one_tick
  exit_code=$?
  if [[ $exit_code -eq 0 ]]; then
    echo "[watchdog] healthy"
  fi
  exit $exit_code
fi
