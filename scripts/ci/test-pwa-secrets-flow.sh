#!/usr/bin/env bash
# INFRA-989: end-to-end test for the PWA secret-input flow.
#
# Verifies:
#   - GET /api/settings/secret/{name} never returns the raw value
#   - POST with CHUMP_SKIP_PROBE=1 stores + chmod 600
#   - POST persistence survives a server restart
#   - Whitelist rejects non-secret-keys (400)
#   - Server log never contains the secret value (presence-only logging)
#   - 422 path: a deliberately bad value (without skip-probe) is rejected
#     and the config.toml is NOT modified

set -euo pipefail

PORT="${CHUMP_TEST_PORT:-38900}"
TEST_VALUE="ghp_test123abcd_INFRA989_marker_xyz"
WORK=$(mktemp -d /tmp/chump-pwa-secrets-test.XXXXXX)
trap 'cleanup' EXIT

cleanup() {
    [[ -n "${WEB_PID:-}" ]] && kill "$WEB_PID" 2>/dev/null || true
    [[ -n "${WEB_PID:-}" ]] && wait "$WEB_PID" 2>/dev/null || true
    rm -rf "$WORK"
}

# INFRA-1602: replace hardcoded /private/tmp/chump-infra-989-v3/... with the
# shared helper (builds ./target/debug/chump if missing; honors CHUMP_BIN).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/ensure-debug-chump.sh"
BIN="$(ensure_debug_chump)" || {
    echo "[test] FAIL: chump binary unavailable (ensure-debug-chump failed)" >&2
    exit 2
}

start_server() {
    CHUMP_HOME="$WORK" CHUMP_SKIP_PROBE="${SKIP_PROBE:-1}" CHUMP_CSRF_ENABLED=0 \
        "$BIN" --web --port "$PORT" >"$WORK/srv.log" 2>&1 &
    WEB_PID=$!
    for _ in $(seq 1 30); do
        if curl -sf "http://localhost:$PORT/api/health" >/dev/null 2>&1; then
            return 0
        fi
        sleep 1
    done
    echo "[test] FAIL: server did not become ready on port $PORT" >&2
    tail -20 "$WORK/srv.log" >&2
    return 1
}

stop_server() {
    [[ -n "${WEB_PID:-}" ]] && kill "$WEB_PID" 2>/dev/null
    [[ -n "${WEB_PID:-}" ]] && wait "$WEB_PID" 2>/dev/null || true
    WEB_PID=""
}

# ── start in probe-skipped mode ──────────────────────────────────────────
start_server

# 1. GET returns set=false for a fresh worktree
echo "[test] GET secret/GH_TOKEN (fresh) → expect set=false"
RESP=$(curl -sf "http://localhost:$PORT/api/settings/secret/GH_TOKEN")
SET=$(echo "$RESP" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("set"))')
LAST4=$(echo "$RESP" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("last4"))')
if [[ "$SET" != "False" ]]; then
    echo "[test] FAIL: fresh GET should be set=False, got set=$SET" >&2
    exit 1
fi
echo "[test] PASS: set=False last4='$LAST4'"

# 2. POST with probe-skipped stores
echo "[test] POST secret/GH_TOKEN value=$TEST_VALUE (probe-skipped)"
RESP=$(curl -sf -X POST -H "Content-Type: application/json" \
    -H "Origin: http://localhost:$PORT" \
    -H "X-CSRF-Token: pwa" \
    -d "{\"value\":\"$TEST_VALUE\"}" \
    "http://localhost:$PORT/api/settings/secret/GH_TOKEN")
if ! echo "$RESP" | grep -q '"stored":true'; then
    echo "[test] FAIL: POST did not confirm stored" >&2
    echo "  got: $RESP" >&2
    exit 1
fi
# Response carries last4 only — assert the raw value is NOT in the response
if echo "$RESP" | grep -q "$TEST_VALUE"; then
    echo "[test] FAIL: POST response leaks the raw secret value" >&2
    echo "  got: $RESP" >&2
    exit 1
fi
echo "[test] PASS: POST stored=true, response does NOT contain raw value"

# 3. config.toml has the value with chmod 600
CONFIG_FILE="$WORK/.chump/config.toml"
if [[ ! -f "$CONFIG_FILE" ]]; then
    echo "[test] FAIL: $CONFIG_FILE not created" >&2
    exit 1
fi
PERMS=$(stat -f '%Lp' "$CONFIG_FILE" 2>/dev/null || stat -c '%a' "$CONFIG_FILE")
if [[ "$PERMS" != "600" ]]; then
    echo "[test] FAIL: config.toml permissions are $PERMS, expected 600" >&2
    exit 1
fi
if ! grep -q "$TEST_VALUE" "$CONFIG_FILE"; then
    echo "[test] FAIL: config.toml does not contain the persisted value" >&2
    exit 1
fi
echo "[test] PASS: config.toml has the value with chmod 600"

# 4. GET after POST → set=true, last4 correct, raw value still absent from response
RESP=$(curl -sf "http://localhost:$PORT/api/settings/secret/GH_TOKEN")
SET=$(echo "$RESP" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("set"))')
LAST4=$(echo "$RESP" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("last4"))')
if [[ "$SET" != "True" || "$LAST4" != "_xyz" ]]; then
    echo "[test] FAIL: post-POST GET unexpected; set=$SET last4='$LAST4' (expected True, '_xyz')" >&2
    exit 1
fi
if echo "$RESP" | grep -q "$TEST_VALUE"; then
    echo "[test] FAIL: GET response leaks raw value after POST" >&2
    exit 1
fi
echo "[test] PASS: GET after POST → set=True last4='$LAST4', NO raw value in response"

# 5. Whitelist guard: POST to a non-listed key → 400
HTTP=$(curl -s -o /dev/null -w '%{http_code}' -X POST \
    -H "Content-Type: application/json" -H "Origin: http://localhost:$PORT" -H "X-CSRF-Token: pwa" \
    -d '{"value":"x"}' \
    "http://localhost:$PORT/api/settings/secret/SOMETHING_NOT_IN_LIST")
if [[ "$HTTP" != "400" ]]; then
    echo "[test] FAIL: non-whitelisted key returned $HTTP, expected 400" >&2
    exit 1
fi
echo "[test] PASS: non-whitelisted key rejected with 400"

# 6. Empty value → 400
HTTP=$(curl -s -o /dev/null -w '%{http_code}' -X POST \
    -H "Content-Type: application/json" -H "Origin: http://localhost:$PORT" -H "X-CSRF-Token: pwa" \
    -d '{"value":""}' \
    "http://localhost:$PORT/api/settings/secret/GH_TOKEN")
if [[ "$HTTP" != "400" ]]; then
    echo "[test] FAIL: empty value returned $HTTP, expected 400" >&2
    exit 1
fi
echo "[test] PASS: empty value rejected with 400"

# 7. Log leak check — the secret value must NOT appear in the server log
if grep -q "$TEST_VALUE" "$WORK/srv.log"; then
    echo "[test] FAIL: server log leaks the raw secret value!" >&2
    grep "$TEST_VALUE" "$WORK/srv.log" | head -3 >&2
    exit 1
fi
echo "[test] PASS: server log does NOT contain raw secret value"

# 8. Restart + verify persistence
stop_server
start_server
RESP=$(curl -sf "http://localhost:$PORT/api/settings/secret/GH_TOKEN")
SET=$(echo "$RESP" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("set"))')
LAST4=$(echo "$RESP" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("last4"))')
if [[ "$SET" != "True" || "$LAST4" != "_xyz" ]]; then
    echo "[test] FAIL: post-restart GET unexpected; set=$SET last4='$LAST4'" >&2
    exit 1
fi
echo "[test] PASS: secret persists across server restart"

# 9. Probe-active path: stop, restart without skip, POST a bad value → 422,
#    config.toml content for ANTHROPIC_API_KEY should NOT change (no entry was
#    there to start; assert absent after the failed POST).
stop_server
SKIP_PROBE=0 start_server

CONFIG_BEFORE=$(cat "$CONFIG_FILE" 2>/dev/null | grep -c "anthropic_api_key" || true)
HTTP=$(curl -s -o /dev/null -w '%{http_code}' -X POST \
    -H "Content-Type: application/json" -H "Origin: http://localhost:$PORT" -H "X-CSRF-Token: pwa" \
    -d '{"value":"sk-ant-INVALID-INFRA989-marker"}' \
    "http://localhost:$PORT/api/settings/secret/ANTHROPIC_API_KEY")
if [[ "$HTTP" != "422" ]]; then
    echo "[test] FAIL: bad ANTHROPIC_API_KEY w/ probe returned $HTTP, expected 422" >&2
    exit 1
fi
CONFIG_AFTER=$(cat "$CONFIG_FILE" 2>/dev/null | grep -c "anthropic_api_key" || true)
if [[ "$CONFIG_AFTER" != "$CONFIG_BEFORE" ]]; then
    echo "[test] FAIL: config.toml modified despite probe failure (before=$CONFIG_BEFORE after=$CONFIG_AFTER)" >&2
    exit 1
fi
echo "[test] PASS: probe failure → 422 + config.toml unchanged"

echo ""
echo "[test] ALL 9 CHECKS PASSED — INFRA-989 secret-input flow verified end-to-end"
