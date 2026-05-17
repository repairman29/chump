#!/usr/bin/env bash
# INFRA-1014: verify the PWA auth middleware enforces CHUMP_WEB_TOKEN on
# /api/* routes (except the documented bypass set: /api/health,
# /api/auth/check), and that /api/auth/check correctly verifies tokens.
#
# Boots `chump --web` on a free port with CHUMP_WEB_TOKEN set, then
# exercises the auth surface end-to-end.

set -euo pipefail

PORT="${CHUMP_TEST_PORT:-38600}"
TOKEN="test-token-infra1014"
WORK=$(mktemp -d /tmp/chump-pwa-auth-test.XXXXXX)
trap 'cleanup' EXIT

cleanup() {
    [[ -n "${WEB_PID:-}" ]] && kill "$WEB_PID" 2>/dev/null || true
    [[ -n "${WEB_PID:-}" ]] && wait "$WEB_PID" 2>/dev/null || true
    rm -rf "$WORK"
}

# INFRA-1602: replace hardcoded /private/tmp/chump-infra-1014/... path with
# the shared helper (builds ./target/debug/chump if missing; honors CHUMP_BIN).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/ensure-debug-chump.sh"
BIN="$(ensure_debug_chump)" || {
    echo "[test] FAIL: chump binary unavailable (ensure-debug-chump failed)" >&2
    exit 2
}

CHUMP_HOME="$WORK" CHUMP_WEB_TOKEN="$TOKEN" CHUMP_CSRF_ENABLED=0 \
    "$BIN" --web --port "$PORT" >"$WORK/srv.log" 2>&1 &
WEB_PID=$!

# Wait for server to bind
for _ in $(seq 1 30); do
    if curl -sf "http://localhost:$PORT/api/health" >/dev/null 2>&1; then
        break
    fi
    sleep 1
done
if ! curl -sf "http://localhost:$PORT/api/health" >/dev/null 2>&1; then
    echo "[test] FAIL: server did not become ready on port $PORT" >&2
    tail -20 "$WORK/srv.log" >&2
    exit 1
fi

# AC #2: /api/settings requires Bearer when CHUMP_WEB_TOKEN is set
HTTP=$(curl -s -o /dev/null -w '%{http_code}' "http://localhost:$PORT/api/settings")
if [[ "$HTTP" != "401" ]]; then
    echo "[test] FAIL: GET /api/settings without auth returned $HTTP, expected 401" >&2
    exit 1
fi
echo "[test] PASS: GET /api/settings without auth → 401"

# AC #4: 401 response carries WWW-Authenticate: Bearer
WWW=$(curl -sI "http://localhost:$PORT/api/settings" | grep -i '^www-authenticate' | head -1)
if ! echo "$WWW" | grep -qi 'Bearer'; then
    echo "[test] FAIL: 401 response missing WWW-Authenticate: Bearer header" >&2
    echo "  got: $WWW" >&2
    exit 1
fi
echo "[test] PASS: 401 includes WWW-Authenticate: Bearer"

# Bypass set: /api/health returns 200 without auth even when token is required
HTTP=$(curl -s -o /dev/null -w '%{http_code}' "http://localhost:$PORT/api/health")
if [[ "$HTTP" != "200" ]]; then
    echo "[test] FAIL: GET /api/health without auth returned $HTTP, expected 200 (bypass)" >&2
    exit 1
fi
echo "[test] PASS: /api/health bypasses auth (200)"

# Correct token → 200
HTTP=$(curl -s -o /dev/null -w '%{http_code}' \
    -H "Authorization: Bearer $TOKEN" \
    "http://localhost:$PORT/api/settings")
if [[ "$HTTP" != "200" ]]; then
    echo "[test] FAIL: GET /api/settings with correct Bearer returned $HTTP, expected 200" >&2
    exit 1
fi
echo "[test] PASS: GET /api/settings with correct Bearer → 200"

# Wrong token → 401
HTTP=$(curl -s -o /dev/null -w '%{http_code}' \
    -H "Authorization: Bearer wrong-token" \
    "http://localhost:$PORT/api/settings")
if [[ "$HTTP" != "401" ]]; then
    echo "[test] FAIL: GET /api/settings with wrong Bearer returned $HTTP, expected 401" >&2
    exit 1
fi
echo "[test] PASS: GET /api/settings with wrong Bearer → 401"

# /api/auth/check accessible without auth + correctly validates token
VALID=$(curl -sf -X POST -H "Content-Type: application/json" \
    -d "{\"token\":\"$TOKEN\"}" \
    "http://localhost:$PORT/api/auth/check" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("valid"))')
if [[ "$VALID" != "True" ]]; then
    echo "[test] FAIL: /api/auth/check with correct token returned valid=$VALID, expected True" >&2
    exit 1
fi
echo "[test] PASS: /api/auth/check with correct token → valid=True"

INVALID=$(curl -sf -X POST -H "Content-Type: application/json" \
    -d '{"token":"wrong"}' \
    "http://localhost:$PORT/api/auth/check" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("valid"))')
if [[ "$INVALID" != "False" ]]; then
    echo "[test] FAIL: /api/auth/check with wrong token returned valid=$INVALID, expected False" >&2
    exit 1
fi
echo "[test] PASS: /api/auth/check with wrong token → valid=False"

# Startup warning is suppressed when token IS set; verify the
# "set — requires Bearer" line is in the log instead.
if ! grep -q "CHUMP_WEB_TOKEN set" "$WORK/srv.log"; then
    echo "[test] FAIL: expected startup line confirming token enforcement; got:" >&2
    grep "CHUMP_WEB_TOKEN" "$WORK/srv.log" >&2 || true
    exit 1
fi
echo "[test] PASS: startup log confirms CHUMP_WEB_TOKEN enforcement"

echo ""
echo "[test] ALL CHECKS PASSED — INFRA-1014 auth middleware verified"
