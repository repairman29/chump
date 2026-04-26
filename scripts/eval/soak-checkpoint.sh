#!/usr/bin/env bash
# Soak checkpoint: capture system metrics and append to docs/SOAK_72H_LOG.md.
# Run manually or via launchd/cron every 4 hours during a soak test.
#
# Usage:
#   ./scripts/eval/soak-checkpoint.sh              # append checkpoint
#   SOAK_T0=1 ./scripts/eval/soak-checkpoint.sh    # mark T0 (pre-flight)
#
# Also saves raw JSON to logs/soak-checkpoint-YYYY-MM-DDTHH.json.

set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
mkdir -p "$ROOT/logs"

HOST="${CHUMP_WEB_HOST:-127.0.0.1}"
PORT="${CHUMP_WEB_PORT:-3000}"
TOKEN="${CHUMP_WEB_TOKEN:-}"
BASE="http://${HOST}:${PORT}"
NOW_UTC="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
NOW_SHORT="$(date -u +%Y-%m-%dT%H)"
DOC="$ROOT/docs/SOAK_72H_LOG.md"
RAW_LOG="$ROOT/logs/soak-checkpoint-${NOW_SHORT}.json"
T0_MARKER="$ROOT/logs/soak-t0.json"

auth_header() {
  if [[ -n "$TOKEN" ]]; then
    echo "Authorization: Bearer $TOKEN"
  else
    echo "X-No-Auth: 1"
  fi
}

echo "== soak-checkpoint: $NOW_UTC =="

# --- Collect metrics ---

# DB sizes
MEMORY_DB="$ROOT/sessions/chump_memory.db"
MEMORY_DB_SIZE="n/a"
MEMORY_WAL="none"
if [[ -f "$MEMORY_DB" ]]; then
  MEMORY_DB_SIZE=$(ls -lh "$MEMORY_DB" 2>/dev/null | awk '{print $5}')
  if [[ -f "${MEMORY_DB}-wal" ]]; then
    MEMORY_WAL=$(ls -lh "${MEMORY_DB}-wal" 2>/dev/null | awk '{print $5}')
  fi
fi

# Logs directory size
LOGS_SIZE="n/a"
if [[ -d "$ROOT/logs" ]]; then
  LOGS_SIZE=$(du -sh "$ROOT/logs" 2>/dev/null | awk '{print $1}')
fi

# Sessions directory size
SESSIONS_SIZE="n/a"
if [[ -d "$ROOT/sessions" ]]; then
  SESSIONS_SIZE=$(du -sh "$ROOT/sessions" 2>/dev/null | awk '{print $1}')
fi

# Model server check
MODEL_STATUS="unknown"
STACK_JSON="{}"
http_code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 "${BASE}/api/health" 2>/dev/null || echo "000")
if [[ "$http_code" == "200" ]]; then
  MODEL_STATUS="web_ok"
  STACK_JSON=$(curl -s --max-time 10 -H "$(auth_header)" "${BASE}/api/stack-status" 2>/dev/null || echo "{}")
else
  MODEL_STATUS="web_unreachable_${http_code}"
fi

# Chump process RSS (macOS/Linux)
CHUMP_RSS="n/a"
CHUMP_PID=$(pgrep -f "target.*chump" 2>/dev/null | head -1 || true)
if [[ -n "$CHUMP_PID" ]]; then
  if [[ "$(uname)" == "Darwin" ]]; then
    CHUMP_RSS=$(ps -o rss= -p "$CHUMP_PID" 2>/dev/null | awk '{printf "%.1fM", $1/1024}')
  else
    CHUMP_RSS=$(ps -o rss= -p "$CHUMP_PID" 2>/dev/null | awk '{printf "%.1fM", $1/1024}')
  fi
fi

# Ship heartbeat status
SHIP_STATUS="stopped"
if pgrep -f "heartbeat-ship" >/dev/null 2>&1; then
  SHIP_STATUS="running"
fi

# Check for SQLite errors in recent logs
SQLITE_ERRORS=0
if [[ -f "$ROOT/logs/chump.log" ]]; then
  SQLITE_ERRORS=$(tail -500 "$ROOT/logs/chump.log" 2>/dev/null | grep -c -i "database is locked\|sqlite.*error" || true)
fi

# Largest log files
LARGEST_LOGS=""
if [[ -d "$ROOT/logs" ]]; then
  LARGEST_LOGS=$(ls -lhS "$ROOT/logs" 2>/dev/null | head -4 | tail -3 | awk '{print $5, $NF}' | tr '\n' '; ')
fi

# --- Save raw JSON ---
cat > "$RAW_LOG" <<ENDJSON
{
  "timestamp": "$NOW_UTC",
  "memory_db_size": "$MEMORY_DB_SIZE",
  "memory_wal": "$MEMORY_WAL",
  "logs_size": "$LOGS_SIZE",
  "sessions_size": "$SESSIONS_SIZE",
  "model_status": "$MODEL_STATUS",
  "chump_rss": "$CHUMP_RSS",
  "ship_heartbeat": "$SHIP_STATUS",
  "sqlite_errors_recent": $SQLITE_ERRORS,
  "largest_logs": "$LARGEST_LOGS",
  "stack_status": $STACK_JSON
}
ENDJSON
echo "Raw checkpoint saved to $RAW_LOG"

# --- Handle T0 marker ---
if [[ "${SOAK_T0:-0}" == "1" ]]; then
  cp "$RAW_LOG" "$T0_MARKER"
  echo "T0 marker saved to $T0_MARKER"

  # Append pre-flight section to doc
  cat >> "$DOC" <<EOF

---

## Soak run: $NOW_UTC (T0 — pre-flight)

| Check | Value |
|-------|-------|
| Time (UTC) | $NOW_UTC |
| memory_db size | $MEMORY_DB_SIZE |
| WAL | $MEMORY_WAL |
| logs/ size | $LOGS_SIZE |
| sessions/ size | $SESSIONS_SIZE |
| Model server | $MODEL_STATUS |
| Chump RSS | $CHUMP_RSS |
| Ship heartbeat | $SHIP_STATUS |
| SQLite errors (last 500 lines) | $SQLITE_ERRORS |

EOF
  echo "T0 pre-flight appended to $DOC"
  exit 0
fi

# --- Append checkpoint to doc ---

# Calculate hours since T0 if marker exists
HOURS_SINCE_T0=""
if [[ -f "$T0_MARKER" ]]; then
  T0_TS=$(python3 -c "
import json
with open('$T0_MARKER') as f:
    d = json.load(f)
from datetime import datetime
t0 = datetime.fromisoformat(d['timestamp'].replace('Z','+00:00'))
now = datetime.fromisoformat('${NOW_UTC}'.replace('Z','+00:00'))
print(int((now - t0).total_seconds() / 3600))
" 2>/dev/null || echo "?")
  HOURS_SINCE_T0="T0+${T0_TS}h"
fi

LABEL="${HOURS_SINCE_T0:-checkpoint}"

cat >> "$DOC" <<EOF

### Checkpoint: $NOW_UTC ($LABEL)

| Metric | Value |
|--------|-------|
| memory_db size | $MEMORY_DB_SIZE |
| WAL | $MEMORY_WAL |
| logs/ size | $LOGS_SIZE |
| sessions/ size | $SESSIONS_SIZE |
| Model server | $MODEL_STATUS |
| Chump RSS | $CHUMP_RSS |
| Ship heartbeat | $SHIP_STATUS |
| SQLite errors (last 500 lines) | $SQLITE_ERRORS |
| Largest logs | $LARGEST_LOGS |

EOF

echo "Checkpoint ($LABEL) appended to $DOC"
echo ""
echo "Summary: db=$MEMORY_DB_SIZE wal=$MEMORY_WAL logs=$LOGS_SIZE rss=$CHUMP_RSS ship=$SHIP_STATUS sqlite_err=$SQLITE_ERRORS"
