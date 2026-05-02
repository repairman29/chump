#!/usr/bin/env bash
# INFRA-254: GET / on the PWA must 301-redirect to /v2/.
# Browser users were landing on the legacy v1 shell at web/index.html;
# every PWA fix since 2026-04 (INFRA-178/184/199, PRODUCT-022) shipped
# against v2/ only, so the bare URL was actively serving a worse UX.
#
# Tauri loads its frontend from tauri.localhost (bundled web/), not from
# axum's /, so this redirect is desktop-safe — only browser users at
# http://localhost:3000/ are affected.
#
# Run from repo root: bash scripts/ci/test-infra-254-pwa-root-redirect.sh

set -e
REPO_ROOT="$(git rev-parse --show-toplevel)"
cd "$REPO_ROOT"

PASS=0
FAIL=0
pass() { echo "[PASS] $1"; PASS=$((PASS+1)); }
fail() { echo "[FAIL] $1"; FAIL=$((FAIL+1)); }

# Pick a free high port so the test never collides with a running dev server.
PORT="$(python3 -c "import socket; s=socket.socket(); s.bind(('',0)); print(s.getsockname()[1]); s.close()")"
LOG="$(mktemp -t chump-infra-247-XXXXXX.log)"
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
CHUMP_PREWARM=0 ./target/debug/chump --web --port "$PORT" >"$LOG" 2>&1 &
PID=$!

# Wait for "listening on" up to 20s.
for _ in $(seq 1 40); do
    if grep -q "listening on" "$LOG" 2>/dev/null; then break; fi
    sleep 0.5
done
if ! grep -q "listening on" "$LOG"; then
    echo "[FAIL] server did not start within 20s; log tail:"
    tail -20 "$LOG"
    exit 1
fi

# Resolve the actually-bound port (start_web_server probes upward if the
# requested port is busy; it logs "listening on http://0.0.0.0:<port>").
BOUND_PORT="$(grep -oE "listening on http://[0-9.]+:([0-9]+)" "$LOG" | grep -oE "[0-9]+$" | head -1)"
[[ -z "$BOUND_PORT" ]] && BOUND_PORT="$PORT"

# Assertion 1: GET / returns a 3xx redirect.
STATUS="$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:${BOUND_PORT}/")"
if [[ "$STATUS" =~ ^30[0-9]$ ]]; then
    pass "GET / returned redirect status ($STATUS)"
else
    fail "GET / returned $STATUS, expected 30x"
fi

# Assertion 2: the Location header points at /v2/.
LOCATION="$(curl -s -o /dev/null -D - "http://127.0.0.1:${BOUND_PORT}/" | grep -i '^location:' | tr -d '\r' | awk '{print $2}')"
if [[ "$LOCATION" == "/v2/" ]]; then
    pass "Location header is /v2/ (got: $LOCATION)"
else
    fail "Location header was '$LOCATION', expected '/v2/'"
fi

# Assertion 3: GET /v2/ still serves the v2 index.html (we didn't break the
# fallback). Look for a v2-only sentinel: the design-token comment block.
V2_BODY="$(curl -s "http://127.0.0.1:${BOUND_PORT}/v2/")"
if echo "$V2_BODY" | grep -q "Design tokens"; then
    pass "GET /v2/ still serves the v2 shell"
else
    fail "GET /v2/ did not serve the v2 shell (no 'Design tokens' marker)"
fi

# Assertion 4: GET /index.html (explicit) still serves v1 — Tauri may
# request the bundled file by path even though it usually loads from the
# embedded webview, and we don't want to 404 the legacy shell yet.
V1_STATUS="$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:${BOUND_PORT}/index.html")"
if [[ "$V1_STATUS" == "200" ]]; then
    pass "GET /index.html still 200s (legacy v1 reachable for now)"
else
    fail "GET /index.html returned $V1_STATUS, expected 200 (we did not delete v1)"
fi

echo ""
echo "Passed: $PASS  Failed: $FAIL"
[ "$FAIL" -eq 0 ]
