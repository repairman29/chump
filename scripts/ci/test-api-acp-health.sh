#!/usr/bin/env bash
# scripts/ci/test-api-acp-health.sh — INFRA-1341
#
# Verifies GET /api/acp/health end-to-end:
#   1. Both clients absent → any_handler_present=false + clients[].present=false
#   2. Zed override present → any_handler_present=true + zed entry flipped
#   3. Schema sanity: clients has 2 entries with full schema fields
#   4. Second call returns identical body (60s in-process cache)

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd -P)"
BIN="$REPO_ROOT/target/debug/chump"
[ -x "$BIN" ] || { echo "[test-api-acp-health] chump binary missing at $BIN" >&2; exit 1; }

PORT="${TEST_PORT:-13854}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"; kill_server' EXIT
ok()   { printf '\033[0;32mPASS\033[0m %s\n' "$*"; }
fail() { printf '\033[0;31mFAIL\033[0m %s\n' "$*"; exit 1; }

SERVER_LOG="$TMP/server.log"
SERVER_PID=""
kill_server() { [ -n "$SERVER_PID" ] && kill "$SERVER_PID" 2>/dev/null; SERVER_PID=""; }

start_server() {
    # Args: ZED_OVERRIDE JETBRAINS_OVERRIDE
    CHUMP_ACP_ZED_OVERRIDE="$1" \
    CHUMP_ACP_JETBRAINS_OVERRIDE="$2" \
    CHUMP_WEB_PORT="$PORT" CHUMP_WEB_TOKEN="" \
        "$BIN" --web > "$SERVER_LOG" 2>&1 &
    SERVER_PID=$!
    for _ in $(seq 1 60); do
        if curl -sf "http://127.0.0.1:$PORT/api/health" >/dev/null 2>&1; then return 0; fi
        sleep 0.5
    done
    fail "server failed to start: $(tail -40 "$SERVER_LOG")"
}

# ── Test 1: both absent → any_handler_present=false ──
start_server absent absent
body=$(curl -s "http://127.0.0.1:$PORT/api/acp/health")
[ "$(printf '%s' "$body" | jq -r '.any_handler_present')" = "false" ] \
    || fail "expected any_handler_present=false, got: $body"
[ "$(printf '%s' "$body" | jq -r '.clients[0].present')" = "false" ] \
    || fail "zed.present should be false"
[ "$(printf '%s' "$body" | jq -r '.clients[1].present')" = "false" ] \
    || fail "jetbrains.present should be false"
[ "$(printf '%s' "$body" | jq -r '.acp_error')" = "null" ] \
    || fail "acp_error should be null on success"
ok "both absent → any_handler_present=false, clients[].present=false"

# ── Test 2: schema completeness ──
# Use `has(...)` because jq's `//` short-circuits on `false` (boolean) too.
for i in 0 1; do
    for field in id name present detected_at version binary_path; do
        has=$(printf '%s' "$body" | jq ".clients[$i] | has(\"$field\")")
        [ "$has" = "true" ] || fail "clients[$i].$field missing"
    done
done
[ -n "$(printf '%s' "$body" | jq -r '.generated_at_iso')" ] || fail "generated_at_iso missing"
ok "schema: 2 clients × full field set + generated_at_iso"

# ── Test 3: 60s cache returns identical body ──
body2=$(curl -s "http://127.0.0.1:$PORT/api/acp/health")
[ "$body" = "$body2" ] || fail "second call should return cached body"
ok "60s cache returns identical body"

kill_server
sleep 0.3

# ── Test 4: Zed override present flips any_handler_present ──
start_server present absent
body3=$(curl -s "http://127.0.0.1:$PORT/api/acp/health")
[ "$(printf '%s' "$body3" | jq -r '.any_handler_present')" = "true" ] \
    || fail "with Zed override=present, any_handler_present should be true; got: $body3"
[ "$(printf '%s' "$body3" | jq -r '.clients[0].id')" = "zed" ] \
    || fail "clients[0].id should be zed"
[ "$(printf '%s' "$body3" | jq -r '.clients[0].present')" = "true" ] \
    || fail "clients[0].present should be true"
ok "Zed present override flips any_handler_present"

kill_server
echo "ALL PASS"
