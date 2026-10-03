#!/usr/bin/env bash
# scripts/ci/test-brain-graph-renderer.sh — INFRA-1558
#
# Validates the /brain Cytoscape.js brain-graph renderer:
#  1. Static wiring: chump-view-brain registered + routed + nav sub-tab
#  2. Vendored Cytoscape.js assets present (air-gap requirement — no CDN)
#  3. DOM template contains #cy-container + loads the vendored cytoscape script
#  4. Backend wiring: /api/brain/graph.json, /api/brain/node/{id}, /api/brain/graph/stream
#  5. HTTP round-trip (if binary available): dev server serves /v2/, brain.js,
#     the vendored cytoscape bundle, and /api/brain/graph.json all 200.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd -P)"
APP_JS="$REPO_ROOT/web/v2/app.js"
BRAIN_JS="$REPO_ROOT/web/v2/brain.js"
INDEX_HTML="$REPO_ROOT/web/v2/index.html"
WEB_SERVER_RS="$REPO_ROOT/src/web_server.rs"
LIB_DIR="$REPO_ROOT/web/v2/lib/cytoscape"
BIN="${CARGO_TARGET_DIR:-$REPO_ROOT/target}/debug/chump"

PASS=0
FAIL=0
ok()   { printf '  \033[0;32mPASS\033[0m %s\n' "$*"; PASS=$((PASS+1)); }
fail() { printf '  \033[0;31mFAIL\033[0m %s\n' "$*"; FAIL=$((FAIL+1)); }

echo "=== INFRA-1558 brain-graph-renderer test ==="
echo

# ── 1. Static wiring ────────────────────────────────────────────────────────
[[ -f "$BRAIN_JS" ]] && ok "web/v2/brain.js exists" || fail "web/v2/brain.js missing"

grep -q "class ChumpViewBrain" "$BRAIN_JS" \
    && ok "ChumpViewBrain class defined" \
    || fail "ChumpViewBrain class missing"

grep -q "customElements.define('chump-view-brain'" "$BRAIN_JS" \
    && ok "chump-view-brain registered" \
    || fail "chump-view-brain not registered"

grep -q "brain:.*chump-view-brain" "$APP_JS" \
    && ok "brain registered in VIEWS router map" \
    || fail "brain missing from VIEWS router map"

grep -q "id: 'brain'" "$APP_JS" \
    && ok "brain sub-tab present in nav cadence" \
    || fail "brain missing from nav cadence subtabs"

grep -q '<script src="brain.js"' "$INDEX_HTML" \
    && ok "brain.js wired into index.html" \
    || fail "brain.js script tag missing from index.html"

# ── 2. Vendored Cytoscape.js (air-gap — no CDN) ─────────────────────────────
for f in cytoscape.min.js layout-base.js cose-base.js cytoscape-fcose.js; do
    [[ -s "$LIB_DIR/$f" ]] \
        && ok "vendored $f present" \
        || fail "vendored $f missing from $LIB_DIR"
done

grep -q "lib/cytoscape/cytoscape.min.js" "$BRAIN_JS" \
    && ok "brain.js loads the vendored cytoscape bundle" \
    || fail "brain.js does not reference the vendored cytoscape bundle"

# ── 3. DOM template ──────────────────────────────────────────────────────────
grep -q 'id="cy-container"' "$BRAIN_JS" \
    && ok "DOM template contains #cy-container" \
    || fail "#cy-container missing from brain.js template"

grep -q "cytoscape({" "$BRAIN_JS" \
    && ok "cytoscape() renderer instantiated" \
    || fail "no cytoscape() call found"

# ── 4. Node-type filters + edge relation colors (AC 3 + 4) ─────────────────
for t in gap pr agent lesson ambient_event; do
    grep -q "'$t'" "$BRAIN_JS" \
        && ok "node-type filter: $t" \
        || fail "node-type filter missing: $t"
done

for rel in blocks references ships applies_lesson claims; do
    grep -q "$rel:" "$BRAIN_JS" \
        && ok "edge relation color: $rel" \
        || fail "edge relation color missing: $rel"
done

# ── 5. Backend wiring ────────────────────────────────────────────────────────
grep -q '"/api/brain/graph.json"' "$WEB_SERVER_RS" \
    && ok "/api/brain/graph.json route present" \
    || fail "/api/brain/graph.json route missing"

grep -q '"/api/brain/node/{id}"' "$WEB_SERVER_RS" \
    && ok "/api/brain/node/{id} route present" \
    || fail "/api/brain/node/{id} route missing"

grep -q '"/api/brain/graph/stream"' "$WEB_SERVER_RS" \
    && ok "/api/brain/graph/stream route present" \
    || fail "/api/brain/graph/stream route missing"

grep -q "pub fn node_detail" "$REPO_ROOT/src/memory_graph_viz.rs" \
    && ok "memory_graph_viz::node_detail present" \
    || fail "memory_graph_viz::node_detail missing"

# ── 6. HTTP round-trip (if binary available) ────────────────────────────────
if [[ ! -x "$BIN" ]]; then
    echo "  [info] chump binary missing at $BIN; skipping HTTP round-trip"
    echo
    echo "=== Results: $PASS passed, $FAIL failed (HTTP tier skipped) ==="
    [[ "$FAIL" -eq 0 ]]
    exit $?
fi

PORT="${TEST_PORT:-13857}"
TMP="$(mktemp -d)"
SERVER_LOG="$TMP/server.log"
SERVER_PID=""
kill_server() { [ -n "$SERVER_PID" ] && kill "$SERVER_PID" 2>/dev/null; SERVER_PID=""; }
trap 'rm -rf "$TMP"; kill_server' EXIT

CHUMP_REPO="$REPO_ROOT" \
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

code=$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT/v2/")
[[ "$code" == "200" ]] && ok "GET /v2/ -> 200" || fail "GET /v2/ -> $code"

code=$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT/v2/brain.js")
[[ "$code" == "200" ]] && ok "GET /v2/brain.js -> 200" || fail "GET /v2/brain.js -> $code"

code=$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT/v2/lib/cytoscape/cytoscape.min.js")
[[ "$code" == "200" ]] && ok "GET /v2/lib/cytoscape/cytoscape.min.js -> 200" || fail "GET cytoscape bundle -> $code"

body=$(curl -s "http://127.0.0.1:$PORT/api/brain/graph.json")
echo "$body" | jq -e 'has("nodes") and has("edges")' >/dev/null 2>&1 \
    && ok "GET /api/brain/graph.json -> {nodes, edges}" \
    || fail "GET /api/brain/graph.json shape mismatch: $body"

code=$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT/api/brain/node/nonexistent-node-xyz")
[[ "$code" == "404" ]] && ok "GET /api/brain/node/<unknown> -> 404" || fail "GET /api/brain/node/<unknown> -> $code (expected 404)"

kill_server
echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
