#!/usr/bin/env bash
# Memory keeper: herd health for Chump memory. Checks DB exists and is readable,
# optionally pings embed server for recall health. Does not edit or prune memory.
#
# Env:
#   CHUMP_HOME                   rust-agent root (default: script dir/..).
#   MEMORY_KEEPER_CHECK_EMBED=1  Also check embed server (default 1 if CHUMP_EMBED_URL set).

set -e
ROOT="${CHUMP_HOME:-$(cd "$(dirname "$0")/.." && pwd)}"
cd "$ROOT"
if [[ -f .env ]]; then set -a; source .env; set +a; fi

LOG="$ROOT/logs/memory-keeper.log"
mkdir -p "$ROOT/logs"
SESSIONS="$ROOT/sessions"

log() { echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $*" | tee -a "$LOG"; }

ok=0
fail=0

# DB exists and readable
if [[ -f "$SESSIONS/chump_memory.db" ]]; then
  if command -v sqlite3 &>/dev/null; then
    if count=$(sqlite3 "$SESSIONS/chump_memory.db" "SELECT COUNT(*) FROM chump_memory" 2>/dev/null); then
      log "Memory DB ok; rows: $count"
      ok=$((ok + 1))
    else
      log "Memory DB unreadable or missing chump_memory table."
      fail=$((fail + 1))
    fi
  else
    log "Memory DB exists (sqlite3 not installed to check rows)."
    ok=$((ok + 1))
  fi
else
  log "No chump_memory.db; memory may be using JSON fallback."
  ok=$((ok + 1))
fi

# Optional: embed server (recall health)
check_embed="${MEMORY_KEEPER_CHECK_EMBED:-}"
[[ -z "$check_embed" ]] && [[ -n "${CHUMP_EMBED_URL:-}" ]] && check_embed=1
if [[ "$check_embed" == "1" ]]; then
  port="${CHUMP_EMBED_PORT:-18765}"
  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 2 "http://127.0.0.1:${port}/" 2>/dev/null || echo "000")
  if [[ "$code" =~ ^(200|404|405)$ ]]; then
    log "Embed server ok (HTTP $code)."
    ok=$((ok + 1))
  else
    log "Embed server down or unreachable (HTTP $code)."
    fail=$((fail + 1))
  fi
fi

if [[ $fail -gt 0 ]]; then
  log "Memory keeper: $ok ok, $fail failed."
  exit 1
fi
log "Memory keeper: all checks ok."
exit 0
