#!/usr/bin/env bash
# INFRA-1558: brain graph visualization renderer smoke test.
# Spins up the dev server, hits /brain, asserts HTTP 200 + DOM contains
# #cy-container + the Cytoscape script is referenced.
#
# Run from repo root: bash scripts/ci/test-brain-graph-renderer.sh

set -e
REPO_ROOT="$(git rev-parse --show-toplevel)"
cd "$REPO_ROOT"

PASS=0
FAIL=0
pass() { echo "[PASS] $1"; PASS=$((PASS+1)); }
fail() { echo "[FAIL] $1"; FAIL=$((FAIL+1)); }

PORT="$(python3 -c "import socket; s=socket.socket(); s.bind(('',0)); print(s.getsockname()[1]); s.close()")"
LOG="$(mktemp -t chump-infra-1558-XXXXXX.log)"
PID=""
cleanup() {
    [[ -n "$PID" ]] && kill "$PID" 2>/dev/null || true
    rm -f "$LOG"
}
trap cleanup EXIT

cargo build --bin chump --quiet 2>&1 | tail -3

CHUMP_BIN_PATH="${CARGO_TARGET_DIR:-./target}/debug/chump"
CHUMP_PREWARM=0 "$CHUMP_BIN_PATH" --web --port "$PORT" >"$LOG" 2>&1 &
PID=$!

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

STATUS="$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:${BOUND_PORT}/brain")"
if [[ "$STATUS" == "200" ]]; then
    pass "GET /brain returned 200"
else
    fail "GET /brain returned $STATUS, expected 200"
fi

BODY="$(curl -s "http://127.0.0.1:${BOUND_PORT}/brain")"
if echo "$BODY" | grep -q 'id="cy-container"'; then
    pass "DOM contains #cy-container"
else
    fail "DOM missing #cy-container"
fi

if echo "$BODY" | grep -qi 'cytoscape'; then
    pass "Cytoscape script is referenced"
else
    fail "Cytoscape script not referenced"
fi

GRAPH_STATUS="$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:${BOUND_PORT}/api/brain/graph.json")"
if [[ "$GRAPH_STATUS" == "200" ]]; then
    pass "GET /api/brain/graph.json returned 200"
else
    fail "GET /api/brain/graph.json returned $GRAPH_STATUS, expected 200"
fi

echo ""
echo "Passed: $PASS  Failed: $FAIL"
[ "$FAIL" -eq 0 ]
