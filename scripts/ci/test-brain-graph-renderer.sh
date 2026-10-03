#!/usr/bin/env bash
# scripts/ci/test-brain-graph-renderer.sh — INFRA-1558
#
# Structural test for the brain graph visualization renderer
# (<chump-view-brain>, web/v2/brain.js): Cytoscape.js force-directed layout
# over /api/brain/graph.json, with node-type filters, click-to-focus detail
# pane, and SSE-driven incremental live updates.
#
# Run modes:
#   bash scripts/ci/test-brain-graph-renderer.sh                    # source audit only
#   CHUMP_BIN=${CARGO_TARGET_DIR:-./target}/debug/chump bash …      # adds live HTTP smoke:
#                                                                      spins up the dev
#                                                                      server, hits /v2/,
#                                                                      asserts HTTP 200 +
#                                                                      brain.js served with
#                                                                      #cy-container + a
#                                                                      Cytoscape script load.

set -uo pipefail

PASS=0; FAIL=0
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
APP_JS="$REPO_ROOT/web/v2/app.js"
INDEX_HTML="$REPO_ROOT/web/v2/index.html"
BRAIN_JS="$REPO_ROOT/web/v2/brain.js"
WS="$REPO_ROOT/src/web_server.rs"

echo "=== INFRA-1558 brain graph renderer tests ==="
echo

# ── 1. Frontend file + custom element present ───────────────────────────────
[[ -f "$BRAIN_JS" ]] && ok "web/v2/brain.js present" || fail "web/v2/brain.js missing"

if grep -q "class ChumpViewBrain" "$BRAIN_JS" 2>/dev/null; then
    ok "ChumpViewBrain class defined"
else
    fail "ChumpViewBrain class missing"
fi

if grep -q "customElements.define('chump-view-brain'" "$BRAIN_JS" 2>/dev/null; then
    ok "chump-view-brain registered"
else
    fail "chump-view-brain not registered"
fi

# ── 2. Scope guard: < 800 LOC frontend (AC#6) ───────────────────────────────
LOC=$(wc -l < "$BRAIN_JS" 2>/dev/null || echo 99999)
if [[ "$LOC" -lt 800 ]]; then
    ok "brain.js is $LOC LOC (< 800 scope guard)"
else
    fail "brain.js is $LOC LOC — exceeds 800 LOC scope guard"
fi

# ── 3. Library choice: Cytoscape.js, not D3/vis.js ──────────────────────────
grep -q "cytoscape" "$BRAIN_JS" 2>/dev/null && ok "Cytoscape.js referenced" \
    || fail "no Cytoscape.js reference found"
if grep -qE "d3\.js|vis-network|vis\.js" "$BRAIN_JS" 2>/dev/null; then
    fail "forbidden library reference found (D3 / vis.js)"
else
    ok "no forbidden library (D3 / vis.js) referenced"
fi

# ── 4. #cy-container + Cytoscape script-load wiring ─────────────────────────
grep -q 'id="cy-container"' "$BRAIN_JS" 2>/dev/null && ok "#cy-container element present" \
    || fail "#cy-container element missing"
grep -q "CYTOSCAPE_CDN" "$BRAIN_JS" 2>/dev/null && ok "Cytoscape script load wired (CDN constant)" \
    || fail "no Cytoscape script-load wiring found"

# ── 5. Force-directed layout: cose-bilkent or fcose (AC#3) ──────────────────
if grep -qE "fcose|cose-bilkent" "$BRAIN_JS" 2>/dev/null; then
    ok "force-directed layout extension referenced (fcose/cose-bilkent)"
else
    fail "no fcose/cose-bilkent layout reference found"
fi

# ── 6. Node-type filters (AC#3) ──────────────────────────────────────────────
for t in gap pr agent lesson ambient_event; do
    grep -q "'$t'" "$BRAIN_JS" 2>/dev/null || fail "missing node-type filter: $t"
done
ok "node-type filters: gap / pr / agent / lesson / ambient_event"

# ── 7. Click node -> focus + right-pane /api/brain/node/{id} fetch (AC#3) ──
grep -q "/api/brain/node/" "$BRAIN_JS" 2>/dev/null && ok "right-pane fetches /api/brain/node/{id}" \
    || fail "missing /api/brain/node/{id} fetch"
grep -q "brain-detail" "$BRAIN_JS" 2>/dev/null && ok "right-pane detail panel present" \
    || fail "missing right-pane detail panel"

# ── 8. Edge color-coding by relation kind (AC#4) ────────────────────────────
for rel in blocks references ships applies_lesson claims; do
    grep -q "$rel" "$BRAIN_JS" 2>/dev/null || fail "missing edge relation color: $rel"
done
ok "edge relation colors: blocks / references / ships / applies_lesson / claims"

# ── 9. Live updates via SSE, incremental (not full reload) (AC#5) ──────────
grep -q "/api/brain/graph/stream" "$BRAIN_JS" 2>/dev/null && ok "subscribes to /api/brain/graph/stream" \
    || fail "missing /api/brain/graph/stream subscription"
if grep -qE "cy\.add\(|#cy\.add\(" "$BRAIN_JS" 2>/dev/null && grep -qE "cy\.getElementById\(.*\)\.remove\(\)|#cy\.getElementById" "$BRAIN_JS" 2>/dev/null; then
    ok "incremental cy.add()/remove() wired for live updates"
else
    fail "no incremental add/remove wiring found (looks like full-reload path)"
fi

# ── 10. View registered in router + nav (library cadence) ──────────────────
grep -q "brain:.*chump-view-brain" "$APP_JS" 2>/dev/null && ok "brain registered in VIEWS router map" \
    || fail "brain missing from VIEWS router map"
grep -q "id: 'brain'" "$APP_JS" 2>/dev/null && ok "Library cadence includes brain sub-tab" \
    || fail "brain missing from Library cadence subtabs"
grep -q 'script src="brain.js"' "$INDEX_HTML" 2>/dev/null && ok "brain.js wired into index.html" \
    || fail "brain.js not <script>-included in index.html"

# ── 11. Backend: /api/brain/graph.json, /node/{id}, /graph/stream (AC#1/#3/#5) ──
grep -q 'route("/api/brain/graph.json"' "$WS" 2>/dev/null && ok "/api/brain/graph.json route present" \
    || fail "/api/brain/graph.json route missing"
grep -q 'route("/api/brain/node/{id}"' "$WS" 2>/dev/null && ok "/api/brain/node/{id} route present" \
    || fail "/api/brain/node/{id} route missing"
grep -q 'route("/api/brain/graph/stream"' "$WS" 2>/dev/null && ok "/api/brain/graph/stream route present" \
    || fail "/api/brain/graph/stream route missing"

echo
echo "--- Live HTTP smoke (requires CHUMP_BIN) ---"
if [[ -z "${CHUMP_BIN:-}" || ! -x "${CHUMP_BIN:-}" ]]; then
    echo "  SKIPPED — set CHUMP_BIN=\${CARGO_TARGET_DIR:-./target}/debug/chump to run the live smoke"
else
    PORT="${CHUMP_TEST_PORT:-38991}"
    WORK=$(mktemp -d /tmp/chump-brain-renderer-test.XXXXXX)
    WEB_PID=""
    cleanup() {
        [[ -n "$WEB_PID" ]] && kill "$WEB_PID" 2>/dev/null || true
        [[ -n "$WEB_PID" ]] && wait "$WEB_PID" 2>/dev/null || true
        rm -rf "$WORK"
    }
    trap cleanup EXIT

    mkdir -p "$WORK/.chump-locks"
    CHUMP_HOME="$WORK" CHUMP_WEB_STATIC_DIR="$REPO_ROOT/web" CHUMP_CSRF_ENABLED=0 \
        "$CHUMP_BIN" --web --port "$PORT" >"$WORK/srv.log" 2>&1 &
    WEB_PID=$!
    for _ in $(seq 1 30); do
        curl -sf "http://localhost:$PORT/api/health" >/dev/null 2>&1 && break
        sleep 1
    done

    if ! curl -sf "http://localhost:$PORT/api/health" >/dev/null 2>&1; then
        fail "dev server did not become ready on port $PORT"
        tail -20 "$WORK/srv.log" >&2
    else
        ok "dev server up on :$PORT"

        SHELL_CODE=$(curl -s -o "$WORK/shell.html" -w '%{http_code}' "http://localhost:$PORT/v2/")
        [[ "$SHELL_CODE" == "200" ]] && ok "GET /v2/ -> HTTP 200" || fail "GET /v2/ -> HTTP $SHELL_CODE"

        BRAIN_JS_CODE=$(curl -s -o "$WORK/brain.js" -w '%{http_code}' "http://localhost:$PORT/v2/brain.js")
        [[ "$BRAIN_JS_CODE" == "200" ]] && ok "GET /v2/brain.js -> HTTP 200" || fail "GET /v2/brain.js -> HTTP $BRAIN_JS_CODE"

        grep -q 'id="cy-container"' "$WORK/brain.js" 2>/dev/null \
            && ok "served brain.js DOM template contains #cy-container" \
            || fail "served brain.js missing #cy-container"
        grep -q "cytoscape" "$WORK/brain.js" 2>/dev/null \
            && ok "served brain.js loads the Cytoscape script" \
            || fail "served brain.js missing Cytoscape script load"

        GRAPH_CODE=$(curl -s -o "$WORK/graph.json" -w '%{http_code}' "http://localhost:$PORT/api/brain/graph.json")
        [[ "$GRAPH_CODE" == "200" ]] && ok "GET /api/brain/graph.json -> HTTP 200" \
            || fail "GET /api/brain/graph.json -> HTTP $GRAPH_CODE"
    fi
fi

echo
echo "=== $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]] || exit 1
