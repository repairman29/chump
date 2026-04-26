#!/usr/bin/env bash
# Run cursor_improve rounds one after another until duration expires or you kill/pause.
# Respects logs/pause: when present, skips rounds (sleeps) until you remove it or resume from the menu.
#
# Requires: same as research-cursor-only.sh (TAVILY_API_KEY, CHUMP_CURSOR_CLI, CURSOR_API_KEY; agent in PATH).
#
# Usage:
#   ./scripts/dev/heartbeat-cursor-improve-loop.sh                    # 8h, round every 5 min (default)
#   HEARTBEAT_INTERVAL=3m ./scripts/dev/heartbeat-cursor-improve-loop.sh   # top out: every 3 min
#   HEARTBEAT_DURATION=4h HEARTBEAT_INTERVAL=15m ./scripts/dev/heartbeat-cursor-improve-loop.sh
#   HEARTBEAT_QUICK_TEST=1 ./scripts/dev/heartbeat-cursor-improve-loop.sh   # 2m, 30s between rounds
#
# Pause: touch logs/pause  (or use Chump Menu → Pause self-improve). Resume: rm logs/pause (or Menu → Resume).

set -e
ROOT="${CHUMP_HOME:-$(cd "$(dirname "$0")/.." && pwd)}"
cd "$ROOT"
export PATH="${HOME}/.local/bin:${HOME}/.cursor/bin:${PATH}"

if [[ -f .env ]]; then
  set -a
  source .env
  set +a
fi
[[ "$CHUMP_TEST_CONFIG" == "max_m4" ]] && [[ -f "$ROOT/scripts/dev/env-max_m4.sh" ]] && source "$ROOT/scripts/dev/env-max_m4.sh"

if [[ -n "${HEARTBEAT_QUICK_TEST:-}" ]]; then
  DURATION="${HEARTBEAT_DURATION:-2m}"
  INTERVAL="${HEARTBEAT_INTERVAL:-30s}"
else
  DURATION="${HEARTBEAT_DURATION:-8h}"
  # Throttle for 8000: longer interval when on vLLM-MLX (default 10m). Ollama default 5m.
  if [[ "${OPENAI_API_BASE:-}" == *":8000"* ]]; then
    INTERVAL="${HEARTBEAT_INTERVAL:-10m}"
  else
    INTERVAL="${HEARTBEAT_INTERVAL:-5m}"
  fi
fi

duration_sec() {
  local v=$1
  if [[ "$v" =~ ^([0-9]+)h$ ]]; then
    echo $((${BASH_REMATCH[1]} * 3600))
  elif [[ "$v" =~ ^([0-9]+)m$ ]]; then
    echo $((${BASH_REMATCH[1]} * 60))
  elif [[ "$v" =~ ^([0-9]+)s$ ]]; then
    echo "${BASH_REMATCH[1]}"
  else
    echo 3600
  fi
}
DURATION_SEC=$(duration_sec "$DURATION")
INTERVAL_SEC=$(duration_sec "$INTERVAL")

LOG="$ROOT/logs/heartbeat-cursor-improve-loop.log"
mkdir -p "$ROOT/logs"

[[ -f "$ROOT/scripts/dev/heartbeat-lock.sh" ]] && source "$ROOT/scripts/dev/heartbeat-lock.sh"
use_heartbeat_lock=0
[[ "${HEARTBEAT_LOCK:-1}" == "1" ]] && [[ "${OPENAI_API_BASE:-}" == *":8000"* ]] && use_heartbeat_lock=1

echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] cursor-improve loop started: duration=$DURATION, interval=$INTERVAL" >> "$LOG"

start_ts=$(date +%s)
round=0

while true; do
  now=$(date +%s)
  elapsed=$((now - start_ts))
  if [[ $elapsed -ge $DURATION_SEC ]]; then
    echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] cursor-improve loop finished after $round rounds." >> "$LOG"
    break
  fi

  if [[ -f "$ROOT/logs/pause" ]] || [[ "${CHUMP_PAUSED:-0}" == "1" ]] || [[ "${CHUMP_PAUSED:-}" == "true" ]]; then
    echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] Round skipped (paused). Remove logs/pause or use Menu → Resume to run again." >> "$LOG"
    sleep "$INTERVAL_SEC"
    continue
  fi

  if [[ "$use_heartbeat_lock" == "1" ]] && ! acquire_heartbeat_lock 120; then
    echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] Round skipped (lock timeout — another round or Discord using model)" >> "$LOG"
    sleep "$INTERVAL_SEC"
    continue
  fi

  round=$((round + 1))
  echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] Round $round: starting cursor_improve" >> "$LOG"
  if "$ROOT/scripts/eval/research-cursor-only.sh" >> "$LOG" 2>&1; then
    echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] Round $round: ok" >> "$LOG"
  else
    echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] Round $round: exit non-zero" >> "$LOG"
  fi

  [[ "$use_heartbeat_lock" == "1" ]] && release_heartbeat_lock

  now=$(date +%s)
  elapsed=$((now - start_ts))
  if [[ $elapsed -ge $DURATION_SEC ]]; then
    echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] cursor-improve loop finished after $round rounds." >> "$LOG"
    break
  fi

  echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] Sleeping $INTERVAL until next round..." >> "$LOG"
  sleep "$INTERVAL_SEC"
done

echo "Cursor-improve loop done. Log: $LOG"
