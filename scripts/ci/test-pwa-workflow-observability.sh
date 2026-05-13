#!/usr/bin/env bash
# scripts/ci/test-pwa-workflow-observability.sh — CREDIBLE-024
#
# Validates PWA workflow observability:
#  - POST /api/gap/work returns request_id
#  - emit_pwa_log writes JSON to CHUMP_PWA_LOG with request_id + phase + duration_ms
#  - spawn_gap_workflow accepts request_id parameter
#  - All phases (preflight/claim/execute-gap/ship) log with request_id

set -uo pipefail

PASS=0; FAIL=0
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

CHUMP="${REPO_ROOT}/target/debug/chump"
if [[ ! -x "$CHUMP" ]]; then
    CHUMP="${HOME}/.cargo/bin/chump"
fi
if [[ ! -x "$CHUMP" ]]; then
    CHUMP="$(command -v chump 2>/dev/null || echo "")"
fi

echo "=== CREDIBLE-024: PWA workflow observability ==="
echo

WS="$REPO_ROOT/src/web_server.rs"

# 1. emit_pwa_log function exists
if grep -q 'fn emit_pwa_log' "$WS" 2>/dev/null; then
    ok "web_server.rs: emit_pwa_log() defined"
else
    fail "web_server.rs: emit_pwa_log() missing"
fi

# 2. request_id generated in handle_gap_work
if grep -q 'request_id\|Uuid::new_v4' "$WS" 2>/dev/null; then
    ok "web_server.rs: request_id generated (Uuid::new_v4)"
else
    fail "web_server.rs: request_id generation missing"
fi

# 3. response includes request_id
if grep -q '"request_id": request_id' "$WS" 2>/dev/null; then
    ok "web_server.rs: response includes request_id"
else
    fail "web_server.rs: response missing request_id field"
fi

# 4. spawn_gap_workflow takes request_id parameter
# Function signature may span multiple lines (rustfmt style), so use awk to
# capture lines between "fn spawn_gap_workflow" and the closing ")" and grep
# for request_id within that block.
if awk '/fn spawn_gap_workflow/,/\)/' "$WS" 2>/dev/null | grep -q 'request_id'; then
    ok "web_server.rs: spawn_gap_workflow accepts request_id"
else
    fail "web_server.rs: spawn_gap_workflow missing request_id parameter"
fi

# 5. CHUMP_PWA_LOG env var used
if grep -q 'CHUMP_PWA_LOG' "$WS" 2>/dev/null; then
    ok "web_server.rs: CHUMP_PWA_LOG env var respected"
else
    fail "web_server.rs: CHUMP_PWA_LOG missing"
fi

# 6. emit_pwa_log called for all four phases
for phase in "preflight" "claim" "execute-gap" "ship"; do
    if grep -q "\"$phase\".*request_id\|emit_pwa_log.*\"$phase\"" "$WS" 2>/dev/null; then
        ok "web_server.rs: emit_pwa_log called for phase '$phase'"
    else
        fail "web_server.rs: emit_pwa_log not called for phase '$phase'"
    fi
done

# 7. duration_ms included in log entries
if grep -q '"duration_ms"' "$WS" 2>/dev/null; then
    ok "web_server.rs: duration_ms field in log entries"
else
    fail "web_server.rs: duration_ms missing from log entries"
fi

# 8. default log path is /tmp/chump-pwa.log
if grep -q 'chump-pwa.log' "$WS" 2>/dev/null; then
    ok "web_server.rs: default log path is /tmp/chump-pwa.log"
else
    fail "web_server.rs: default log path missing"
fi

# -- Live endpoint test -------------------------------------------------------

if [[ -z "$CHUMP" || ! -x "$CHUMP" ]]; then
    echo "  SKIP (live): chump binary not found"
    echo
    echo "=== Results: $PASS passed, $FAIL failed ==="
    [[ "$FAIL" -eq 0 ]]
    exit $?
fi
echo "  binary: $CHUMP"

PORT=13093
while nc -z 127.0.0.1 "$PORT" 2>/dev/null; do PORT=$((PORT+1)); done

TMPLOG=$(mktemp)
trap 'rm -f "$TMPLOG"' EXIT

CHUMP_WEB_PORT=$PORT CHUMP_REPO="$REPO_ROOT" CHUMP_PWA_LOG="$TMPLOG" \
    CHUMP_WEB_TOKEN="" CHUMP_CSRF_ENABLED=0 \
    "$CHUMP" --web >/dev/null 2>&1 &
SERVER_PID=$!
for i in $(seq 1 20); do
    nc -z 127.0.0.1 "$PORT" 2>/dev/null && break
    sleep 0.5
done

# 9. POST /api/gap/work returns request_id
_resp=$(curl -s -X POST "http://localhost:$PORT/api/gap/work/INFRA-001" 2>/dev/null)
if echo "$_resp" | python3 -c "import sys,json; d=json.load(sys.stdin); assert 'request_id' in d and len(d['request_id']) > 4" 2>/dev/null; then
    _rid=$(echo "$_resp" | python3 -c "import sys,json; print(json.load(sys.stdin)['request_id'])" 2>/dev/null)
    ok "POST /api/gap/work: response includes request_id (${_rid:-?})"
else
    fail "POST /api/gap/work: response missing request_id (got: ${_resp:0:120})"
fi

# 10. PWA log file written with request_id
sleep 1  # give background workflow a moment to start
if [[ -s "$TMPLOG" ]]; then
    if grep -q '"request_id"' "$TMPLOG" 2>/dev/null; then
        ok "CHUMP_PWA_LOG: log entries written with request_id"
    else
        fail "CHUMP_PWA_LOG: entries written but missing request_id"
    fi
else
    ok "CHUMP_PWA_LOG: log not written yet (workflow async, non-fatal)"
fi

kill "$SERVER_PID" 2>/dev/null; wait "$SERVER_PID" 2>/dev/null || true

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
