#!/usr/bin/env bash
# test-fleet-scrubber.sh — INFRA-2176
#
# Smoke test for web/fleet-scrubber/index.html.
#
# Asserts:
#   1. D3 v7 CDN script tag present
#   2. Required element IDs: #timeline, #lanes, #live-toggle, #replay-btn, #side-panel
#   3. Activity color CSS variables: --color-claim, --color-edit, --color-push,
#      --color-merge, --color-blocked, --color-idle
#   4. fixtures/segments.json and fixtures/events.json exist and are valid JSON
#   5. fixtures/gen.py exists and is executable
#
# The test serves the page via python3 http.server on an ephemeral port and
# asserts on the raw HTML (curl); no browser required.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
WEB_DIR="$REPO_ROOT/web/fleet-scrubber"

PASS=0
FAIL=0
FAILURES=()

ok()  { echo "  [PASS] $1"; PASS=$((PASS + 1)); }
bad() { echo "  [FAIL] $1"; FAIL=$((FAIL + 1)); FAILURES+=("$1"); }

# ── Start ephemeral HTTP server ───────────────────────────────────────────────
PORT=$(python3 -c "import socket; s=socket.socket(); s.bind(('',0)); print(s.getsockname()[1]); s.close()")
python3 -m http.server --directory "$WEB_DIR" "$PORT" >/dev/null 2>&1 &
SERVER_PID=$!
HTML_TMP=""
trap 'kill $SERVER_PID 2>/dev/null || true; [[ -n "${HTML_TMP:-}" ]] && rm -f "$HTML_TMP"' EXIT

# Give the server a moment
sleep 0.4

# Fetch the page
HTML=$(curl -sf "http://localhost:$PORT/index.html" 2>&1) || {
    echo "FAIL: could not fetch http://localhost:$PORT/index.html"
    kill $SERVER_PID 2>/dev/null || true
    exit 1
}

echo "=== test-fleet-scrubber.sh ==="
echo ""
echo "--- Test 1: D3 v7 CDN script tag ---"
if echo "$HTML" | grep -q 'src="https://d3js.org/d3.v7.min.js"'; then
    ok "D3 v7 CDN script tag present"
else
    bad "D3 v7 CDN script tag missing (expected: src=\"https://d3js.org/d3.v7.min.js\")"
fi

echo ""
echo "--- Test 2: Required element IDs ---"
for id in "id=\"timeline\"" "id=\"lanes\"" "id=\"live-toggle\"" "id=\"replay-btn\"" "id=\"side-panel\""; do
    if echo "$HTML" | grep -q "$id"; then
        ok "Element $id present"
    else
        bad "Element $id missing"
    fi
done

echo ""
echo "--- Test 3: Activity color CSS variables ---"
# Write HTML to a temp file so we can search it with python3 (avoids grep flag issues
# with CSS variable names that start with --)
HTML_TMP="$(mktemp /tmp/fleet-scrubber-test-XXXXXX.html)"
printf '%s' "$HTML" > "$HTML_TMP"
for var in "--color-claim" "--color-edit" "--color-push" "--color-merge" "--color-blocked" "--color-idle"; do
    if python3 -c "import sys; content=open('$HTML_TMP').read(); sys.exit(0 if '$var' in content else 1)"; then
        ok "CSS variable $var present"
    else
        bad "CSS variable $var missing"
    fi
done

echo ""
echo "--- Test 4: Fixture files exist and are valid JSON ---"
SEGMENTS_JSON="$WEB_DIR/fixtures/segments.json"
EVENTS_JSON="$WEB_DIR/fixtures/events.json"

if [[ -f "$SEGMENTS_JSON" ]]; then
    if python3 -c "import json,sys; data=json.load(open('$SEGMENTS_JSON')); assert isinstance(data, list) and len(data) > 0" 2>/dev/null; then
        COUNT=$(python3 -c "import json; print(len(json.load(open('$SEGMENTS_JSON'))))")
        ok "fixtures/segments.json is valid JSON with $COUNT entries"
    else
        bad "fixtures/segments.json is invalid JSON or empty"
    fi
else
    bad "fixtures/segments.json not found"
fi

if [[ -f "$EVENTS_JSON" ]]; then
    if python3 -c "import json,sys; data=json.load(open('$EVENTS_JSON')); assert isinstance(data, list) and len(data) > 0" 2>/dev/null; then
        COUNT=$(python3 -c "import json; print(len(json.load(open('$EVENTS_JSON'))))")
        ok "fixtures/events.json is valid JSON with $COUNT entries"
    else
        bad "fixtures/events.json is invalid JSON or empty"
    fi
else
    bad "fixtures/events.json not found"
fi

echo ""
echo "--- Test 5: Fixture generator exists ---"
GEN_PY="$WEB_DIR/fixtures/gen.py"
if [[ -f "$GEN_PY" ]]; then
    ok "fixtures/gen.py exists"
else
    bad "fixtures/gen.py not found"
fi

echo ""
echo "--- Test 6: chump-fleet-view.sh exists and is executable ---"
VIEW_SH="$REPO_ROOT/scripts/dev/chump-fleet-view.sh"
if [[ -x "$VIEW_SH" ]]; then
    ok "scripts/dev/chump-fleet-view.sh is executable"
else
    bad "scripts/dev/chump-fleet-view.sh not found or not executable"
fi

echo ""
echo "--- Test 7: README exists ---"
README="$WEB_DIR/README.md"
if [[ -f "$README" ]]; then
    ok "web/fleet-scrubber/README.md exists"
else
    bad "web/fleet-scrubber/README.md not found"
fi

echo ""
echo "--- Test 8: ?fixtures=1 mode URL switch present in JS ---"
if echo "$HTML" | grep -q 'USE_FIXTURES'; then
    ok "Fixture mode URL switch (USE_FIXTURES) present in JS"
else
    bad "Fixture mode URL switch missing"
fi

echo ""
echo "=== Results: ${PASS} passed, ${FAIL} failed ==="

if [[ $FAIL -gt 0 ]]; then
    echo ""
    echo "Failures:"
    for f in "${FAILURES[@]}"; do echo "  - $f"; done
    exit 1
fi

exit 0
