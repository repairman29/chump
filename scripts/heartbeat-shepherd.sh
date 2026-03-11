#!/usr/bin/env bash
# Heartbeat shepherd: ensures the heartbeat job ran recently and succeeded.
# Checks last run in logs/heartbeat-learn.log; if last round failed, optionally retries once (quick round).
# Run from cron/launchd every 15–30 min, or manually. Does not start the long 8h heartbeat — only checks/retries.
#
# Env:
#   HEARTBEAT_SHEPHERD_RETRY=1   If last round failed, run one quick round to verify model (default 0).
#   CHUMP_HOME                   rust-agent root (default: script dir/..).

set -e
ROOT="${CHUMP_HOME:-$(cd "$(dirname "$0")/.." && pwd)}"
cd "$ROOT"
if [[ -f .env ]]; then set -a; source .env; set +a; fi

LOG="$ROOT/logs/heartbeat-shepherd.log"
mkdir -p "$ROOT/logs"

log() { echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $*" | tee -a "$LOG"; }

HEARTBEAT_LOG="$ROOT/logs/heartbeat-learn.log"
if [[ ! -f "$HEARTBEAT_LOG" ]]; then
  log "No heartbeat log yet; nothing to shepherd."
  exit 0
fi

# Last non-empty line that indicates outcome (ok vs failed)
last_ok=
last_fail=
while IFS= read -r line; do
  if [[ "$line" == *"Round "*": ok"* ]] || [[ "$line" == *"Round "*": ok (after retry)"* ]]; then
    last_ok="$line"
    last_fail=
  elif [[ "$line" == *"Round "*": exit non-zero"* ]] || [[ "$line" == *"Round "*": retry failed"* ]]; then
    last_fail="$line"
  fi
done < <(tail -n 200 "$HEARTBEAT_LOG" 2>/dev/null)

if [[ -n "$last_fail" ]] && [[ -z "$last_ok" ]]; then
  # Last recorded outcome was failure (and no ok after it)
  log "Last heartbeat round failed: $last_fail"
  if [[ "${HEARTBEAT_SHEPHERD_RETRY:-0}" == "1" ]]; then
    log "Running one quick round to verify model..."
    if HEARTBEAT_QUICK_TEST=1 ./scripts/heartbeat-learn.sh >> "$HEARTBEAT_LOG" 2>&1; then
      log "Quick round ok; model is up."
    else
      log "Quick round failed; model or Tavily may be down."
      exit 1
    fi
  else
    exit 1
  fi
elif [[ -n "$last_ok" ]]; then
  log "Last heartbeat round ok."
  exit 0
else
  log "No round outcome found in last 200 lines."
  exit 0
fi
