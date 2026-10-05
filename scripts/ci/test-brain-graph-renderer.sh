#!/usr/bin/env bash
# scripts/ci/test-brain-graph-renderer.sh — INFRA-1558
#
# Smoke test for the /brain Cytoscape.js graph renderer:
#   1. /api/brain/graph.json returns {"nodes":[...],"edges":[...]} shape
#   2. /api/brain/graph/stream exists and is routed (SSE headers)
#   3. web/v2/index.html wires up the vendored Cytoscape bundle + brain.js
#   4. web/v2/brain.js defines #cy-container and registers chump-view-brain
#   5. web/v2/app.js registers the 'brain' view + nav subtab

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"; [[ -n "${SERVER_PID:-}" ]] && kill "$SERVER_PID" 2>/dev/null || true' EXIT

ok()   { printf '\033[0;32mPASS\033[0m %s\n' "$*"; }
fail() { printf '\033[0;31mFAIL\033[0m %s\n' "$*"; exit 1; }

source "$(dirname "$0")/lib/discover-chump-bin.sh"
[[ -x "$CHUMP_BIN" ]] || fail "no chump binary at $CHUMP_BIN (set CHUMP_BIN)"

mkdir -p "$TMP/.chump-locks"
PORT=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')
LOG="$TMP/server.log"

CHUMP_REPO="$TMP" \
CHUMP_WEB_STATIC_DIR="$REPO_ROOT/web" \
CHUMP_BINARY_STALENESS_CHECK=0 \
    "$CHUMP_BIN" --web --port "$PORT" >"$LOG" 2>&1 &
SERVER_PID=$!

for _ in $(seq 1 50); do
    sleep 0.2
    curl -sf "http://127.0.0.1:$PORT/api/health" >/dev/null 2>&1 && break
done
curl -sf "http://127.0.0.1:$PORT/api/health" >/dev/null \
    || fail "server failed to start (log: $(cat "$LOG"))"

# ── Test 1: /api/brain/graph.json shape ────────────────────────────────────
R="$TMP/graph.json"
curl -sf "http://127.0.0.1:$PORT/api/brain/graph.json" >"$R" \
    || fail "GET /api/brain/graph.json failed"
python3 - <<EOF
import json
d = json.load(open("$R"))
assert "nodes" in d and isinstance(d["nodes"], list), "nodes missing/not a list"
assert "edges" in d and isinstance(d["edges"], list), "edges missing/not a list"
EOF
ok "GET /api/brain/graph.json returns {nodes, edges}"

# ── Test 2: /api/brain/graph/stream is routed as SSE ───────────────────────
STREAM_HEADERS="$TMP/stream_headers.txt"
curl -sf --max-time 2 -D "$STREAM_HEADERS" -o /dev/null \
    "http://127.0.0.1:$PORT/api/brain/graph/stream" || true
grep -qi "^content-type: text/event-stream" "$STREAM_HEADERS" \
    || fail "/api/brain/graph/stream did not return text/event-stream"
ok "GET /api/brain/graph/stream returns text/event-stream"

# ── Test 3: HTTP 200 for the PWA shell + DOM/wiring assertions ─────────────
INDEX="$TMP/index.html"
curl -sf "http://127.0.0.1:$PORT/v2/" >"$INDEX" \
    || fail "GET /v2/ (PWA shell) failed"

grep -q 'lib/vendor/cytoscape.min.js' "$INDEX" \
    || fail "index.html does not load the vendored cytoscape bundle"
grep -q 'brain.js' "$INDEX" \
    || fail "index.html does not load brain.js"
ok "HTTP 200 + index.html wires up cytoscape + brain.js"

# ── Test 4: brain.js defines #cy-container and the custom element ─────────
BRAIN_JS="$REPO_ROOT/web/v2/brain.js"
[[ -f "$BRAIN_JS" ]] || fail "web/v2/brain.js not found"
grep -q 'cy-container' "$BRAIN_JS" || fail "brain.js does not define #cy-container"
grep -q "customElements.define('chump-view-brain'" "$BRAIN_JS" \
    || fail "brain.js does not register chump-view-brain"
ok "brain.js defines #cy-container + chump-view-brain"

# ── Test 5: app.js routes the 'brain' view ─────────────────────────────────
APP_JS="$REPO_ROOT/web/v2/app.js"
grep -q "brain:.*chump-view-brain" "$APP_JS" \
    || fail "app.js VIEWS does not map 'brain' to chump-view-brain"
ok "app.js registers the 'brain' view"

ok "ALL INFRA-1558 brain-graph-renderer checks passed"
