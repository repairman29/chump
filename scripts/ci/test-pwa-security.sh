#!/usr/bin/env bash
# scripts/ci/test-pwa-security.sh — CREDIBLE-023
#
# Validates PWA /api/gap/* security hardening:
#  - validate_gap_id() rejects malformed IDs
#  - check_csrf() requires X-CSRF-Token on POST
#  - check_gap_rate_limit() enforces per-IP window
#  - gap_security_headers_middleware wires X-Frame-Options etc.
#  - run_subprocess_with_timeout wraps subprocess calls
#  - Struct/function presence in web_server.rs

set -uo pipefail

PASS=0; FAIL=0
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
WS="$REPO_ROOT/src/web_server.rs"

echo "=== CREDIBLE-023: PWA gap endpoint security ==="
echo

# 1. validate_gap_id function defined
if grep -q 'fn validate_gap_id' "$WS" 2>/dev/null; then
    ok "web_server.rs: validate_gap_id() defined"
else
    fail "web_server.rs: validate_gap_id() missing"
fi

# 2. check_csrf function defined
if grep -q 'fn check_csrf' "$WS" 2>/dev/null; then
    ok "web_server.rs: check_csrf() defined"
else
    fail "web_server.rs: check_csrf() missing"
fi

# 3. check_gap_rate_limit function defined
if grep -q 'fn check_gap_rate_limit' "$WS" 2>/dev/null; then
    ok "web_server.rs: check_gap_rate_limit() defined"
else
    fail "web_server.rs: check_gap_rate_limit() missing"
fi

# 4. rate limit uses 60-second window
if grep -q 'window_secs.*60\|60.*window' "$WS" 2>/dev/null; then
    ok "web_server.rs: 60-second rate limit window"
else
    fail "web_server.rs: 60-second window missing"
fi

# 5. security headers middleware defined
if grep -q 'fn gap_security_headers_middleware' "$WS" 2>/dev/null; then
    ok "web_server.rs: gap_security_headers_middleware() defined"
else
    fail "web_server.rs: gap_security_headers_middleware() missing"
fi

# 6. X-Frame-Options header set
if grep -q 'x-frame-options\|X-Frame-Options' "$WS" 2>/dev/null; then
    ok "web_server.rs: X-Frame-Options header present"
else
    fail "web_server.rs: X-Frame-Options header missing"
fi

# 7. Content-Security-Policy header set
if grep -q 'content-security-policy\|Content-Security-Policy' "$WS" 2>/dev/null; then
    ok "web_server.rs: Content-Security-Policy header present"
else
    fail "web_server.rs: Content-Security-Policy header missing"
fi

# 8. X-Content-Type-Options header set
if grep -q 'x-content-type-options\|X-Content-Type-Options' "$WS" 2>/dev/null; then
    ok "web_server.rs: X-Content-Type-Options header present"
else
    fail "web_server.rs: X-Content-Type-Options header missing"
fi

# 9. subprocess timeout helper defined
if grep -q 'fn run_subprocess_with_timeout' "$WS" 2>/dev/null; then
    ok "web_server.rs: run_subprocess_with_timeout() defined"
else
    fail "web_server.rs: run_subprocess_with_timeout() missing"
fi

# 10. default 300s subprocess timeout
if grep -q '300' "$WS" 2>/dev/null && grep -q 'SUBPROCESS_TIMEOUT\|timeout_secs' "$WS" 2>/dev/null; then
    ok "web_server.rs: 5-minute (300s) subprocess timeout configured"
else
    fail "web_server.rs: 300s timeout not wired"
fi

# 11. validate_gap_id called in handle_gap_work (search whole file — only gap handlers use it)
if grep -q 'validate_gap_id.*gap_id\|gap_id.*validate_gap_id\|validate_gap_id(&gap_id)' "$WS" 2>/dev/null; then
    ok "web_server.rs: validate_gap_id() called in gap handlers"
else
    fail "web_server.rs: validate_gap_id() not called in gap handlers"
fi

# 12. CSRF check wired in gap handler (POST endpoints)
if grep -q 'check_csrf(&headers)' "$WS" 2>/dev/null; then
    ok "web_server.rs: check_csrf() called in gap handlers"
else
    fail "web_server.rs: check_csrf() not called in gap handlers"
fi

# 13. rate limit wired in gap handlers
if grep -q 'check_gap_rate_limit' "$WS" 2>/dev/null; then
    _rl_count=$(grep -c 'check_gap_rate_limit' "$WS" 2>/dev/null || echo 0)
    if [[ "$_rl_count" -ge 2 ]]; then
        ok "web_server.rs: check_gap_rate_limit() called in gap handlers (${_rl_count}x)"
    else
        fail "web_server.rs: check_gap_rate_limit() only 1 call — should be in multiple handlers"
    fi
else
    fail "web_server.rs: check_gap_rate_limit() not wired in gap handlers"
fi

# 14. gap_security_headers_middleware wired in build_api_router
if grep -q 'gap_security_headers_middleware' "$WS" 2>/dev/null; then
    _count=$(grep -c 'gap_security_headers_middleware' "$WS" 2>/dev/null || echo 0)
    if [[ "$_count" -ge 2 ]]; then
        ok "web_server.rs: gap_security_headers_middleware wired in router (def + layer)"
    else
        fail "web_server.rs: gap_security_headers_middleware referenced only once (not wired?)"
    fi
else
    fail "web_server.rs: gap_security_headers_middleware not referenced"
fi

# -- Functional tests via in-process Rust ----------------------------------------

CHUMP="${REPO_ROOT}/target/debug/chump"
[[ ! -x "$CHUMP" ]] && CHUMP="${HOME}/.cargo/bin/chump"
[[ ! -x "$CHUMP" ]] && CHUMP="$(command -v chump 2>/dev/null || echo "")"

if [[ -z "$CHUMP" || ! -x "$CHUMP" ]]; then
    echo "  SKIP (live): chump binary not found"
    echo
    echo "=== Results: $PASS passed, $FAIL failed ==="
    [[ "$FAIL" -eq 0 ]]
    exit $?
fi
# Skip live tests if binary predates CREDIBLE-023 (doesn't have validate_gap_id)
if ! strings "$CHUMP" 2>/dev/null | grep -q 'validate_gap_id\|CREDIBLE-023\|CHUMP_CSRF_ENABLED' 2>/dev/null; then
    echo "  SKIP (live): binary predates CREDIBLE-023 (no validate_gap_id symbol)"
    echo
    echo "=== Results: $PASS passed, $FAIL failed ==="
    [[ "$FAIL" -eq 0 ]]
    exit $?
fi
echo "  binary: $CHUMP"

PORT=13099
while nc -z 127.0.0.1 "$PORT" 2>/dev/null; do PORT=$((PORT+1)); done

TMPLOG=$(mktemp)
trap 'kill "$SERVER_PID" 2>/dev/null; wait "$SERVER_PID" 2>/dev/null || true; rm -f "$TMPLOG"' EXIT

CHUMP_CSRF_ENABLED=0 CHUMP_WEB_PORT=$PORT CHUMP_REPO="$REPO_ROOT" \
    "$CHUMP" --web >/dev/null 2>&1 &
SERVER_PID=$!
for i in $(seq 1 20); do
    nc -z 127.0.0.1 "$PORT" 2>/dev/null && break
    sleep 0.5
done

# 15. POST /api/gap/work with invalid gap_id returns 400
_code=$(curl -s -o /dev/null -w "%{http_code}" -X POST \
    "http://localhost:$PORT/api/gap/work/not-valid-id-123" 2>/dev/null)
if [[ "$_code" == "400" ]]; then
    ok "POST /api/gap/work/not-valid-id-123: returns 400 (invalid gap_id)"
else
    fail "POST /api/gap/work/not-valid-id-123: expected 400, got $_code"
fi

# 16. POST /api/gap/work without X-CSRF-Token returns 403 (CSRF enabled)
CHUMP_CSRF_ENABLED=1 CHUMP_WEB_PORT=$PORT CHUMP_REPO="$REPO_ROOT" \
    kill "$SERVER_PID" 2>/dev/null; wait "$SERVER_PID" 2>/dev/null || true
CHUMP_CSRF_ENABLED=1 CHUMP_WEB_PORT=$PORT CHUMP_REPO="$REPO_ROOT" \
    "$CHUMP" --web >/dev/null 2>&1 &
SERVER_PID=$!
for i in $(seq 1 20); do nc -z 127.0.0.1 "$PORT" 2>/dev/null && break; sleep 0.5; done

_code=$(curl -s -o /dev/null -w "%{http_code}" -X POST \
    "http://localhost:$PORT/api/gap/work/INFRA-001" 2>/dev/null)
if [[ "$_code" == "403" ]]; then
    ok "POST /api/gap/work/INFRA-001 (no CSRF token): returns 403"
else
    fail "POST /api/gap/work/INFRA-001 (no CSRF token): expected 403, got $_code"
fi

# 17. GET /api/health returns X-Frame-Options: DENY? (only on gap routes)
# Actually security headers only on /api/gap/* — check a gap route
kill "$SERVER_PID" 2>/dev/null; wait "$SERVER_PID" 2>/dev/null || true
CHUMP_CSRF_ENABLED=0 CHUMP_WEB_PORT=$PORT CHUMP_REPO="$REPO_ROOT" \
    "$CHUMP" --web >/dev/null 2>&1 &
SERVER_PID=$!
for i in $(seq 1 20); do nc -z 127.0.0.1 "$PORT" 2>/dev/null && break; sleep 0.5; done

_xfo=$(curl -s -I "http://localhost:$PORT/api/gap-queue" 2>/dev/null | grep -i 'x-frame-options' || true)
if echo "$_xfo" | grep -qi 'DENY'; then
    ok "GET /api/gap-queue: X-Frame-Options: DENY present"
else
    fail "GET /api/gap-queue: X-Frame-Options: DENY missing (got: $_xfo)"
fi

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
