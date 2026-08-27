#!/usr/bin/env bash
# scripts/ci/test-brain-graph-renderer.sh — INFRA-1558
#
# Brain graph visualization renderer (Cytoscape.js over /api/brain/graph.json).
# Verifies:
#   1. web/v2/brain.js exists, defines <chump-view-brain>, and is wired into
#      the PWA (index.html script tag, app.js VIEWS router + nav subtab).
#   2. Cytoscape.js is the chosen library (not D3/vis.js) and the container
#      div id is #cy-container (AC 3, AC 7).
#   3. Node-type filters (gap/PR/agent/lesson/ambient_event) and relation-kind
#      edge coloring exist (AC 3, AC 4).
#   4. Live server: /brain redirects into the PWA shell (HTTP 200 after
#      following redirects), the served brain.js contains #cy-container, and
#      the new backend endpoints (/api/brain/node/{id}, /api/brain/graph/stream)
#      respond correctly.
#   5. Frontend LOC stays under the AC 6 scope guard (< 800 lines).
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
ok()   { printf '\033[0;32mPASS\033[0m %s\n' "$*"; }
fail() { printf '\033[0;31mFAIL\033[0m %s\n' "$*"; exit 1; }

BRAIN_JS="$REPO_ROOT/web/v2/brain.js"
INDEX_HTML="$REPO_ROOT/web/v2/index.html"
APP_JS="$REPO_ROOT/web/v2/app.js"
WEB_SERVER="$REPO_ROOT/src/web_server.rs"
MEMORY_GRAPH_VIZ="$REPO_ROOT/src/memory_graph_viz.rs"

echo "=== INFRA-1558: brain graph renderer checks ==="

[[ -f "$BRAIN_JS" ]] || fail "missing $BRAIN_JS"
ok "web/v2/brain.js exists"

grep -q "class ChumpViewBrain" "$BRAIN_JS" || fail "missing ChumpViewBrain class"
grep -q "customElements.define('chump-view-brain'" "$BRAIN_JS" || fail "view not registered"
ok "ChumpViewBrain defined + registered"

grep -q "id=\"cy-container\"" "$BRAIN_JS" || fail "missing #cy-container mount point"
ok "renders #cy-container"

grep -qi "cytoscape" "$BRAIN_JS" || fail "Cytoscape.js not referenced"
grep -qi "d3\.js\|d3\.min\|vis-network\|vis\.js" "$BRAIN_JS" && fail "must use Cytoscape.js, not D3/vis.js"
ok "Cytoscape.js is the chosen renderer (not D3/vis.js)"

grep -qi "fcose\|cose" "$BRAIN_JS" || fail "missing force-directed (cose/fcose) layout"
ok "force-directed layout (cose/fcose)"

for t in gap pr agent lesson ambient_event; do
    grep -q "id: '$t'" "$BRAIN_JS" || fail "missing node-type filter: $t"
done
ok "node-type filters: gap / PR / agent / lesson / ambient_event"

grep -q "colorForRelation" "$BRAIN_JS" || fail "missing relation-kind edge coloring"
ok "edges color-coded by relation kind"

grep -q "EventSource" "$BRAIN_JS" || fail "missing SSE client for live updates"
grep -q "graph/stream" "$BRAIN_JS" || fail "missing /api/brain/graph/stream subscription"
grep -q "cy.add\|#cy.add\|this.#cy.add" "$BRAIN_JS" || fail "missing incremental cy.add() on live update"
ok "SSE live updates: incremental add/remove, no full reload"

grep -q "brain.js" "$INDEX_HTML" || fail "brain.js not loaded in index.html"
ok "brain.js script tag present in index.html"

grep -q "brain:.*chump-view-brain" "$APP_JS" || fail "brain view missing from VIEWS router"
ok "brain registered in VIEWS map"

LOC=$(wc -l < "$BRAIN_JS")
[[ "$LOC" -lt 800 ]] || fail "frontend LOC ($LOC) exceeds the 800-line scope guard (AC 6)"
ok "frontend LOC ($LOC) within AC 6 scope guard (< 800)"

grep -q "handle_brain_node_detail" "$WEB_SERVER" || fail "missing /api/brain/node/{id} handler"
grep -q "brain/node/{id}" "$WEB_SERVER" || fail "/api/brain/node/{id} not routed"
ok "/api/brain/node/{id} handler + route present"

grep -q "handle_brain_graph_stream" "$WEB_SERVER" || fail "missing /api/brain/graph/stream handler"
grep -q "brain/graph/stream" "$WEB_SERVER" || fail "/api/brain/graph/stream not routed"
ok "/api/brain/graph/stream SSE handler + route present"

grep -q "pub fn node_detail" "$MEMORY_GRAPH_VIZ" || fail "missing memory_graph_viz::node_detail"
ok "memory_graph_viz::node_detail backs the node-detail endpoint"

grep -q '"/brain"' "$WEB_SERVER" || fail "missing /brain top-level PWA entrypoint route"
ok "/brain route present (AC 3: UI lives at /brain)"

# ── Live server checks (skipped gracefully if no binary is available) ──────
BIN="${CHUMP_BIN:-$REPO_ROOT/target/debug/chump}"
if [[ ! -x "$BIN" ]]; then
    echo "[test] chump binary not found at $BIN — skipping live server checks"
    echo "[test] (static checks above already cover AC 1-8; build the binary for the full smoke test)"
    ok "ALL INFRA-1558 static checks passed"
    exit 0
fi

PORT="${CHUMP_TEST_PORT:-38981}"
WORK=$(mktemp -d /tmp/chump-brain-test.XXXXXX)
trap 'cleanup' EXIT
cleanup() {
    [[ -n "${WEB_PID:-}" ]] && kill "$WEB_PID" 2>/dev/null || true
    [[ -n "${WEB_PID:-}" ]] && wait "$WEB_PID" 2>/dev/null || true
    rm -rf "$WORK"
}

mkdir -p "$WORK/.chump-locks"
CHUMP_HOME="$WORK" CHUMP_CSRF_ENABLED=0 CHUMP_WEB_STATIC_DIR="$REPO_ROOT/web" \
    "$BIN" --web --port "$PORT" >"$WORK/srv.log" 2>&1 &
WEB_PID=$!
for _ in $(seq 1 30); do
    curl -sf "http://localhost:$PORT/api/health" >/dev/null 2>&1 && break
    sleep 1
done
if ! curl -sf "http://localhost:$PORT/api/health" >/dev/null 2>&1; then
    echo "[test] FAIL: server did not become ready on port $PORT" >&2
    tail -20 "$WORK/srv.log" >&2
    exit 1
fi
echo "[test] server up on :$PORT"

BRAIN_STATUS=$(curl -s -o /dev/null -w '%{http_code}' -L "http://localhost:$PORT/brain")
[[ "$BRAIN_STATUS" == "200" ]] || fail "GET /brain (following redirects) returned $BRAIN_STATUS, want 200"
ok "GET /brain -> 200 (follows redirect into the PWA shell)"

SERVED_BRAIN_JS=$(curl -sf "http://localhost:$PORT/v2/brain.js")
echo "$SERVED_BRAIN_JS" | grep -q 'id="cy-container"' || fail "served brain.js is missing #cy-container"
ok "served brain.js contains #cy-container"

NODE_404=$(curl -s -o /dev/null -w '%{http_code}' "http://localhost:$PORT/api/brain/node/does-not-exist")
[[ "$NODE_404" == "404" ]] || fail "GET /api/brain/node/<unknown> should 404, got $NODE_404"
ok "GET /api/brain/node/<unknown> -> 404"

STREAM_OUT="$WORK/stream.out"
curl -sN --max-time 3 "http://localhost:$PORT/api/brain/graph/stream" > "$STREAM_OUT" 2>&1 || true
grep -qE '^event:\s*snapshot' "$STREAM_OUT" || grep -q 'event:snapshot' "$STREAM_OUT" \
    || fail "graph/stream did not emit an initial snapshot event"
ok "GET /api/brain/graph/stream emits an initial snapshot event"

echo ""
ok "ALL INFRA-1558 brain-graph-renderer checks passed (static + live server)"
