#!/usr/bin/env bash
# test-brain-graph-renderer.sh — INFRA-1558
#
# Smoke test for the brain-graph visualization renderer (web/v2/brain.js):
#  1. Static wiring: /brain route + /api/brain/node/{id} + /api/brain/graph/stream
#     registered in web_server.rs, handler + page files exist.
#  2. HTTP round-trip (if binary available): spin up a dev server, hit /brain,
#     assert HTTP 200 + DOM contains #cy-container + the Cytoscape script tag.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd -P)"
BIN="${CARGO_TARGET_DIR:-$REPO_ROOT/target}/debug/chump"

PASS=0
FAIL=0
ok()   { printf '  \033[0;32mPASS\033[0m %s\n' "$*"; PASS=$((PASS+1)); }
fail() { printf '  \033[0;31mFAIL\033[0m %s\n' "$*"; FAIL=$((FAIL+1)); }

echo "=== INFRA-1558 brain-graph renderer test ==="
echo

# ── 1. Static wiring ────────────────────────────────────────────────────────
grep -q 'handle_brain_page' "$REPO_ROOT/src/web_server.rs" \
    && ok "handle_brain_page defined in web_server.rs" \
    || fail "handle_brain_page missing from web_server.rs"

grep -q '"/brain"' "$REPO_ROOT/src/web_server.rs" \
    && ok "/brain route registered" \
    || fail "/brain route missing"

grep -q '"/api/brain/node/{id}"' "$REPO_ROOT/src/web_server.rs" \
    && ok "/api/brain/node/{id} route registered" \
    || fail "/api/brain/node/{id} route missing"

grep -q '"/api/brain/graph/stream"' "$REPO_ROOT/src/web_server.rs" \
    && ok "/api/brain/graph/stream route registered" \
    || fail "/api/brain/graph/stream route missing"

[[ -f "$REPO_ROOT/web/v2/brain.html" ]] \
    && ok "web/v2/brain.html exists" \
    || fail "web/v2/brain.html missing"

[[ -f "$REPO_ROOT/web/v2/brain.js" ]] \
    && ok "web/v2/brain.js exists" \
    || fail "web/v2/brain.js missing"

grep -q 'cy-container' "$REPO_ROOT/web/v2/brain.html" \
    && ok "brain.html declares #cy-container" \
    || fail "#cy-container missing from brain.html"

grep -q 'cytoscape' "$REPO_ROOT/web/v2/brain.html" \
    && ok "brain.html loads the Cytoscape.js script" \
    || fail "Cytoscape.js script tag missing from brain.html"

# ── 2. HTTP round-trip ───────────────────────────────────────────────────────
if [[ ! -x "$BIN" ]]; then
    echo "  [info] chump binary missing at $BIN; skipping HTTP round-trip"
    echo
    echo "=== Results: $PASS passed, $FAIL failed (HTTP tier skipped) ==="
    [[ "$FAIL" -eq 0 ]]
    exit $?
fi

PORT="${TEST_PORT:-13857}"
TMP="$(mktemp -d)"
SERVER_PID=""
kill_server() { [ -n "$SERVER_PID" ] && kill "$SERVER_PID" 2>/dev/null; SERVER_PID=""; }
trap 'rm -rf "$TMP"; kill_server' EXIT

SANDBOX_ROOT="$TMP/repo"
mkdir -p "$SANDBOX_ROOT/.chump" "$SANDBOX_ROOT/.chump-locks"

SERVER_LOG="$TMP/server.log"
CHUMP_REPO="$SANDBOX_ROOT" \
    CHUMP_WEB_PORT="$PORT" CHUMP_WEB_TOKEN="" \
    "$BIN" --web > "$SERVER_LOG" 2>&1 &
SERVER_PID=$!
for _ in $(seq 1 60); do
    if curl -sf "http://127.0.0.1:$PORT/api/health" >/dev/null 2>&1; then break; fi
    sleep 0.5
done
if ! curl -sf "http://127.0.0.1:$PORT/api/health" >/dev/null 2>&1; then
    fail "server failed to start: $(tail -20 "$SERVER_LOG")"
    echo
    echo "=== Results: $PASS passed, $FAIL failed ==="
    exit 1
fi

status=$(curl -s -o "$TMP/brain.html" -w '%{http_code}' "http://127.0.0.1:$PORT/brain")
[ "$status" = "200" ] \
    && ok "GET /brain returns HTTP 200" \
    || fail "GET /brain returned HTTP $status"

grep -q 'cy-container' "$TMP/brain.html" \
    && ok "response DOM contains #cy-container" \
    || fail "response DOM missing #cy-container"

grep -qi 'cytoscape' "$TMP/brain.html" \
    && ok "response DOM loads Cytoscape script" \
    || fail "response DOM missing Cytoscape script reference"

node_status=$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT/api/brain/node/nonexistent-node")
[ "$node_status" = "200" ] \
    && ok "GET /api/brain/node/{id} returns HTTP 200 for unknown id" \
    || fail "GET /api/brain/node/{id} returned HTTP $node_status"

kill_server
echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
