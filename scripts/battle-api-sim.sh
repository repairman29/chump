#!/usr/bin/env bash
# Black-box HTTP "battle" against a running Chump web server (no LLM). Finds API/auth/JSON bugs fast.
#
# Prereq: chump --web (or release binary) listening on CHUMP_WEB_PORT (default 3000).
#   CHUMP_WEB_TOKEN must match the server if the server enforces auth.
#
# Usage:
#   ./scripts/battle-api-sim.sh
#   CHUMP_WEB_PORT=3000 CHUMP_WEB_HOST=127.0.0.1 ./scripts/battle-api-sim.sh
#
# Logs: logs/battle-api-sim.log
# Exit: 0 all scenarios pass, 1 otherwise
#
# If GET /api/pilot-summary returns 404, rebuild the web binary (route added in recent releases):
#   cargo build --release && target/release/chump --web --port ...

set -euo pipefail
ROOT="${CHUMP_HOME:-$(cd "$(dirname "$0")/.." && pwd)}"
cd "$ROOT"
mkdir -p "$ROOT/logs"
LOG="$ROOT/logs/battle-api-sim.log"

if [[ -f .env ]]; then
  set -a
  # shellcheck source=/dev/null
  source .env
  set +a
fi

HOST="${CHUMP_WEB_HOST:-127.0.0.1}"
PORT="${CHUMP_WEB_PORT:-3000}"
BASE="http://${HOST}:${PORT}"
BODY=$(mktemp)
trap 'rm -f "$BODY"' EXIT

AUTH=()
if [[ -n "${CHUMP_WEB_TOKEN:-}" ]]; then
  AUTH=(-H "Authorization: Bearer ${CHUMP_WEB_TOKEN}")
fi

ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }

log() { echo "[$(ts)] $*" | tee -a "$LOG"; }

fail() {
  log "FAIL: $*"
  FAILS=$((FAILS + 1))
}

pass() { log "OK: $*"; }

FAILS=0

need_curl() {
  command -v curl >/dev/null 2>&1 || {
    echo "curl required" >&2
    exit 2
  }
}

http_code() {
  local method="$1" path="$2"
  shift 2
  curl -sS -o "$BODY" -w "%{http_code}" -X "$method" "$@" "${BASE}${path}" 2>/dev/null || echo "000"
}

json_has() {
  local key="$1"
  if command -v jq >/dev/null 2>&1; then
    jq -e ".$key" "$BODY" >/dev/null 2>&1
  else
    grep -q "\"$key\"" "$BODY"
  fi
}

check_reachable() {
  local c
  c=$(http_code GET /api/health)
  if [[ "$c" != "200" ]]; then
    log "Web not reachable at $BASE (GET /api/health -> $c). Start Chump web on this port, e.g.: CHUMP_WEB_PORT=$PORT ./run-web.sh   or: cargo run -- --web --port $PORT"
    exit 3
  fi
  if ! json_has service; then
    log "Port $PORT returned HTTP 200 but not Chump (missing JSON 'service'). Another app may be bound here; use CHUMP_WEB_PORT=3000 (or a free port) and ./run-web.sh."
    exit 3
  fi
  if command -v jq >/dev/null 2>&1; then
    if ! jq -e '.service == "chump-web"' "$BODY" >/dev/null 2>&1; then
      log "GET /api/health is not chump-web (wrong service on port $PORT). Pick a free port for Chump web."
      exit 3
    fi
  else
    grep -q '"service"[[:space:]]*:[[:space:]]*"chump-web"' "$BODY" 2>/dev/null || {
      log "GET /api/health missing service chump-web (install jq for stricter checks). Wrong process on port $PORT?"
      exit 3
    }
  fi
}

need_curl
log "=== Battle API sim base=$BASE ===" | tee -a "$LOG"
check_reachable

# --- Scenarios ---
c=$(http_code GET /api/health)
if [[ "$c" == "200" ]] && json_has status; then pass "GET /api/health"; else fail "GET /api/health (code=$c)"; fi

c=$(http_code GET /api/cascade-status)
if [[ "$c" == "200" ]]; then pass "GET /api/cascade-status"; else fail "GET /api/cascade-status (code=$c)"; fi

c=$(http_code GET /api/tasks "${AUTH[@]+"${AUTH[@]}"}")
if [[ "$c" == "200" ]]; then pass "GET /api/tasks"; else fail "GET /api/tasks (code=$c)"; fi

c=$(http_code POST /api/tasks "${AUTH[@]+"${AUTH[@]}"}" -H "Content-Type: application/json" -d '{"title":""}')
if [[ "$c" == "400" ]]; then pass "POST /api/tasks empty title -> 400"; else fail "POST empty title expected 400 got $c"; fi

c=$(http_code POST /api/tasks "${AUTH[@]+"${AUTH[@]}"}" -H "Content-Type: application/json" -d 'not-json')
if [[ "$c" == "422" ]] || [[ "$c" == "400" ]]; then
  pass "POST /api/tasks invalid JSON -> $c"
else
  fail "POST invalid JSON expected 422/400 got $c"
fi

SIM_TITLE="battle-api-sim $(date +%s)"
c=$(http_code POST /api/tasks "${AUTH[@]+"${AUTH[@]}"}" -H "Content-Type: application/json" -d "{\"title\":\"${SIM_TITLE}\",\"priority\":3}")
if [[ "$c" == "200" ]]; then pass "POST /api/tasks create"; else fail "POST create task (code=$c)"; fi

c=$(http_code GET /api/pilot-summary "${AUTH[@]+"${AUTH[@]}"}")
if [[ "$c" == "200" ]] && json_has tasks_total; then pass "GET /api/pilot-summary"; else fail "GET /api/pilot-summary (code=$c)"; fi

c=$(http_code GET /api/briefing "${AUTH[@]+"${AUTH[@]}"}")
if [[ "$c" == "200" ]]; then pass "GET /api/briefing"; else fail "GET /api/briefing (code=$c)"; fi

c=$(http_code GET /api/dashboard "${AUTH[@]+"${AUTH[@]}"}")
if [[ "$c" == "200" ]]; then pass "GET /api/dashboard"; else fail "GET /api/dashboard (code=$c)"; fi

c=$(http_code GET /api/sessions "${AUTH[@]+"${AUTH[@]}"}")
if [[ "$c" == "200" ]]; then pass "GET /api/sessions"; else fail "GET /api/sessions (code=$c)"; fi

c=$(http_code GET /api/autopilot/status "${AUTH[@]+"${AUTH[@]}"}")
if [[ "$c" == "200" ]]; then pass "GET /api/autopilot/status"; else fail "GET /api/autopilot/status (code=$c)"; fi

c=$(http_code GET /api/research "${AUTH[@]+"${AUTH[@]}"}")
if [[ "$c" == "200" ]]; then pass "GET /api/research"; else fail "GET /api/research (code=$c)"; fi

c=$(http_code GET /api/projects "${AUTH[@]+"${AUTH[@]}"}")
if [[ "$c" == "200" ]]; then pass "GET /api/projects"; else fail "GET /api/projects (code=$c)"; fi

c=$(http_code POST /api/projects "${AUTH[@]+"${AUTH[@]}"}" -H "Content-Type: application/json" -d '{"name":""}')
if [[ "$c" == "400" ]]; then pass "POST /api/projects empty name -> 400"; else fail "POST projects empty name expected 400 got $c"; fi

c=$(http_code GET /api/watch "${AUTH[@]+"${AUTH[@]}"}")
if [[ "$c" == "200" ]]; then pass "GET /api/watch"; else fail "GET /api/watch (code=$c)"; fi

c=$(http_code GET /api/push/vapid-public-key "${AUTH[@]+"${AUTH[@]}"}")
if [[ "$c" == "200" ]] && json_has vapid_public_key; then pass "GET /api/push/vapid-public-key"; else fail "GET vapid key (code=$c)"; fi

c=$(http_code GET / "${AUTH[@]+"${AUTH[@]}"}")
if [[ "$c" == "200" ]] || [[ "$c" == "304" ]]; then pass "GET / (static)"; else fail "GET / static (code=$c)"; fi

# Wrong bearer when server requires token
if [[ -n "${CHUMP_WEB_TOKEN:-}" ]]; then
  c=$(http_code GET /api/tasks -H "Authorization: Bearer definitely-wrong-token")
  if [[ "$c" == "401" ]]; then pass "GET /api/tasks wrong bearer -> 401"; else fail "wrong bearer expected 401 got $c"; fi
fi

# DELETE non-existent id: handler returns 204 (abandon is a no-op when no row)
c=$(http_code DELETE /api/tasks/999999999 "${AUTH[@]+"${AUTH[@]}"}")
if [[ "$c" == "204" ]]; then pass "DELETE /api/tasks/999999999 -> 204"; else fail "DELETE ghost task expected 204 got $c"; fi

# --- G7 Analytics endpoint ---
c=$(http_code GET /api/analytics "${AUTH[@]+"${AUTH[@]}"}")
if [[ "$c" == "200" ]] && json_has total_sessions; then pass "GET /api/analytics"; else fail "GET /api/analytics (code=$c)"; fi

# --- G7 Message feedback (non-existent message → 404) ---
c=$(http_code POST /api/messages/999999999/feedback "${AUTH[@]+"${AUTH[@]}"}" -H "Content-Type: application/json" -d '{"feedback":1}')
if [[ "$c" == "404" ]]; then pass "POST /api/messages/999999999/feedback -> 404"; else fail "POST feedback ghost msg expected 404 got $c"; fi

log "=== Done: failures=$FAILS ==="
if [[ "$FAILS" -gt 0 ]]; then
  exit 1
fi
exit 0
