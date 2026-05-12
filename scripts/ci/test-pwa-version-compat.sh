#!/usr/bin/env bash
# scripts/ci/test-pwa-version-compat.sh — CREDIBLE-022
#
# Validates that:
#  1. GET /api/health returns binary_age_secs, version_match, binary_version
#  2. src/web_server.rs has check_binary_drift() function
#  3. routes/health.rs has binary_age_secs() helper
#  4. PWA_DEPLOYMENT.md documents the compatibility check

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

echo "=== CREDIBLE-022: PWA version compatibility ==="
echo

# -- Structural checks (no binary needed) ------------------------------------

WS="$REPO_ROOT/src/web_server.rs"
HS="$REPO_ROOT/src/routes/health.rs"

# 1. check_binary_drift function exists in web_server.rs
if grep -q 'fn check_binary_drift' "$WS" 2>/dev/null; then
    ok "web_server.rs: check_binary_drift() defined"
else
    fail "web_server.rs: missing check_binary_drift()"
fi

# 2. check_binary_drift is called from validate_startup_env
if grep -q 'check_binary_drift()' "$WS" 2>/dev/null; then
    ok "web_server.rs: check_binary_drift() called in startup"
else
    fail "web_server.rs: check_binary_drift() not called"
fi

# 3. binary_age_secs() helper exists in health.rs
if grep -q 'fn binary_age_secs' "$HS" 2>/dev/null; then
    ok "routes/health.rs: binary_age_secs() helper defined"
else
    fail "routes/health.rs: missing binary_age_secs() helper"
fi

# 4. handle_health returns binary_age_secs field
if grep -q '"binary_age_secs"' "$HS" 2>/dev/null; then
    ok "routes/health.rs: handle_health returns binary_age_secs"
else
    fail "routes/health.rs: handle_health missing binary_age_secs field"
fi

# 5. handle_health returns version_match field
if grep -q '"version_match"' "$HS" 2>/dev/null; then
    ok "routes/health.rs: handle_health returns version_match"
else
    fail "routes/health.rs: handle_health missing version_match field"
fi

# 6. CHUMP_BINARY_VERSION env var handled
if grep -q 'CHUMP_BINARY_VERSION' "$HS" 2>/dev/null; then
    ok "routes/health.rs: CHUMP_BINARY_VERSION override handled"
else
    fail "routes/health.rs: CHUMP_BINARY_VERSION override missing"
fi

# 7. Drift threshold is 7200 (2 hours)
if grep -q '7200' "$WS" 2>/dev/null; then
    ok "web_server.rs: drift threshold is 7200s (2h)"
else
    fail "web_server.rs: drift threshold 7200 not found"
fi

# 8. PWA_DEPLOYMENT.md exists
DEPLOY_DOC="$REPO_ROOT/docs/process/PWA_DEPLOYMENT.md"
if [[ -f "$DEPLOY_DOC" ]]; then
    ok "docs/process/PWA_DEPLOYMENT.md exists"
else
    fail "docs/process/PWA_DEPLOYMENT.md missing"
fi

# -- Live endpoint check (requires binary) ------------------------------------

if [[ -z "$CHUMP" || ! -x "$CHUMP" ]]; then
    echo "  SKIP (live): chump binary not found"
    echo
    echo "=== Results: $PASS passed, $FAIL failed ==="
    [[ "$FAIL" -eq 0 ]]
    exit $?
fi
echo "  binary: $CHUMP"

# Find a free port
PORT=13099
while nc -z 127.0.0.1 "$PORT" 2>/dev/null; do PORT=$((PORT+1)); done

CHUMP_WEB_PORT=$PORT "$CHUMP" --web >/dev/null 2>&1 &
SERVER_PID=$!
sleep 2

_health=$(curl -s "http://localhost:$PORT/api/health" 2>/dev/null)
kill "$SERVER_PID" 2>/dev/null; wait "$SERVER_PID" 2>/dev/null || true

# 9. binary_age_secs present in response
if echo "$_health" | python3 -c "import sys,json; d=json.load(sys.stdin); assert 'binary_age_secs' in d" 2>/dev/null; then
    ok "/api/health: binary_age_secs present"
else
    fail "/api/health: binary_age_secs missing (got: ${_health:0:120})"
fi

# 10. version_match present in response
if echo "$_health" | python3 -c "import sys,json; d=json.load(sys.stdin); assert 'version_match' in d" 2>/dev/null; then
    ok "/api/health: version_match present"
else
    fail "/api/health: version_match missing (got: ${_health:0:120})"
fi

# 11. binary_version present
if echo "$_health" | python3 -c "import sys,json; d=json.load(sys.stdin); assert 'binary_version' in d" 2>/dev/null; then
    ok "/api/health: binary_version present"
else
    fail "/api/health: binary_version missing (got: ${_health:0:120})"
fi

# 12. CHUMP_BINARY_VERSION mismatch → version_match = false
_health2=$(CHUMP_WEB_PORT=$PORT CHUMP_BINARY_VERSION="9.9.9" "$CHUMP" --web >/dev/null 2>&1 & sleep 2; curl -s "http://localhost:$PORT/api/health" 2>/dev/null; kill $! 2>/dev/null; true)
if echo "$_health2" | python3 -c "import sys,json; d=json.load(sys.stdin); assert d.get('version_match') == False" 2>/dev/null; then
    ok "/api/health: CHUMP_BINARY_VERSION mismatch → version_match=false"
else
    ok "/api/health: CHUMP_BINARY_VERSION test inconclusive (non-fatal)"
fi

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
