#!/usr/bin/env bash
# INFRA-1558: /brain must serve the Cytoscape.js brain-graph renderer.
# Spins up a real dev server, hits /brain, and asserts HTTP 200 + the DOM
# contains #cy-container + the Cytoscape script tag is present.
#
# Run from repo root: bash scripts/ci/test-brain-graph-renderer.sh

set -e
REPO_ROOT="$(git rev-parse --show-toplevel)"
cd "$REPO_ROOT"

PASS=0
FAIL=0
pass() { echo "[PASS] $1"; PASS=$((PASS+1)); }
fail() { echo "[FAIL] $1"; FAIL=$((FAIL+1)); }

# Pick a free high port so the test never collides with a running dev server.
PORT="$(python3 -c "import socket; s=socket.socket(); s.bind(('',0)); print(s.getsockname()[1]); s.close()")"
LOG="$(mktemp -t chump-infra-1558-XXXXXX.log)"
PID=""
cleanup() {
    [[ -n "$PID" ]] && kill "$PID" 2>/dev/null || true
    rm -f "$LOG"
}
trap cleanup EXIT

# Build first (no-op if up to date).
cargo build --bin chump --quiet 2>&1 | tail -3

# Boot the server in the background. CHUMP_PREWARM=0 skips the Ollama
# warm-up call (we don't need an LLM for this test).
CHUMP_BIN_PATH="${CARGO_TARGET_DIR:-./target}/debug/chump"
CHUMP_PREWARM=0 "$CHUMP_BIN_PATH" --web --port "$PORT" >"$LOG" 2>&1 &
PID=$!

# Wait for "listening on" up to 60s (mirrors test-infra-254-pwa-root-redirect.sh).
for _ in $(seq 1 120); do
    if grep -q "listening on" "$LOG" 2>/dev/null; then break; fi
    sleep 0.5
done
if ! grep -q "listening on" "$LOG"; then
    echo "[FAIL] server did not start within 60s; log tail:"
    tail -20 "$LOG"
    exit 1
fi

BOUND_PORT="$(grep -oE "listening on http://[0-9.]+:([0-9]+)" "$LOG" | grep -oE "[0-9]+$" | head -1)"
[[ -z "$BOUND_PORT" ]] && BOUND_PORT="$PORT"
BASE="http://127.0.0.1:${BOUND_PORT}"

# Assertion 1: GET /brain returns 200.
STATUS="$(curl -s -o /dev/null -w '%{http_code}' "${BASE}/brain")"
if [[ "$STATUS" == "200" ]]; then
    pass "GET /brain returned 200"
else
    fail "GET /brain returned $STATUS, expected 200"
fi

BODY="$(curl -s "${BASE}/brain")"

# Assertion 2: DOM contains #cy-container.
if echo "$BODY" | grep -q 'id="cy-container"'; then
    pass "response contains #cy-container"
else
    fail "response missing #cy-container"
fi

# Assertion 3: Cytoscape script is loaded.
if echo "$BODY" | grep -q "cytoscape"; then
    pass "response references the Cytoscape script"
else
    fail "response does not reference Cytoscape"
fi

# Assertion 4: the brain.js renderer module is served statically and loads.
JS_STATUS="$(curl -s -o /dev/null -w '%{http_code}' "${BASE}/v2/brain.js")"
if [[ "$JS_STATUS" == "200" ]]; then
    pass "GET /v2/brain.js returned 200"
else
    fail "GET /v2/brain.js returned $JS_STATUS, expected 200"
fi

# Assertion 5: /api/brain/graph.json still works (renderer's data source stays live).
API_STATUS="$(curl -s -o /dev/null -w '%{http_code}' "${BASE}/api/brain/graph.json")"
if [[ "$API_STATUS" == "200" ]]; then
    pass "GET /api/brain/graph.json returned 200"
else
    fail "GET /api/brain/graph.json returned $API_STATUS, expected 200"
fi

echo ""
echo "Passed: $PASS  Failed: $FAIL"
[ "$FAIL" -eq 0 ]
