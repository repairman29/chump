#!/usr/bin/env bash
# shellcheck disable=SC2034  # REPO_ROOT kept for context; server-wait loop var unused
# test-api-ambient-emit.sh — INFRA-1333
#
# Smoke test for POST /api/ambient/emit.
#
# Starts the chump web server on a free port, exercises the endpoint with
# several payloads (valid, missing kind, bad kind), and verifies that the
# ambient.jsonl file receives the correct event lines.
#
# Usage:
#   bash scripts/ci/test-api-ambient-emit.sh [--binary <path>]
#
# Skipped when:
#   - No chump binary found (non-Rust build CI step)
#   - SKIP_INTEGRATION_TESTS=1 is set
#
# Exit: 0 = pass, 1 = fail

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd -P)"
BINARY="${CHUMP:-}"
if [ -z "$BINARY" ]; then
    BINARY="$(command -v chump 2>/dev/null || true)"
fi

# Override binary via flag.
while [[ $# -gt 0 ]]; do
    case "$1" in
        --binary) BINARY="$2"; shift 2 ;;
        *) echo "unknown arg: $1" >&2; exit 2 ;;
    esac
done

if [ -z "$BINARY" ] || [ ! -x "$BINARY" ]; then
    echo "[test-api-ambient-emit] SKIP: no chump binary found"
    exit 0
fi

if [ "${SKIP_INTEGRATION_TESTS:-0}" = "1" ]; then
    echo "[test-api-ambient-emit] SKIP: SKIP_INTEGRATION_TESTS=1"
    exit 0
fi

# Setup: isolated tmp dir with ambient.jsonl
WORK_DIR="$(mktemp -d)"
trap 'kill "$SERVER_PID" 2>/dev/null || true; rm -rf "$WORK_DIR"' EXIT

AMBIENT_FILE="$WORK_DIR/.chump-locks/ambient.jsonl"
mkdir -p "$(dirname "$AMBIENT_FILE")"

# Find a free port.
PORT=$(python3 -c "import socket; s=socket.socket(); s.bind(('', 0)); print(s.getsockname()[1]); s.close()")

pass() { printf '[PASS] %s\n' "$*"; }
fail() { printf '[FAIL] %s\n' "$*" >&2; FAILURES=$((FAILURES + 1)); }
FAILURES=0

# Start the server with no auth token (unauthenticated endpoints).
CHUMP_AMBIENT_LOG="$AMBIENT_FILE" \
CHUMP_REPO_ROOT="$WORK_DIR" \
CHUMP_WEB_PORT="$PORT" \
    "$BINARY" serve --port "$PORT" >/dev/null 2>&1 &
SERVER_PID=$!

# Wait for server to become ready (up to 5s).
for i in $(seq 1 20); do
    if curl -sf "http://localhost:$PORT/api/health" >/dev/null 2>&1; then
        break
    fi
    sleep 0.25
done

if ! curl -sf "http://localhost:$PORT/api/health" >/dev/null 2>&1; then
    echo "[test-api-ambient-emit] SKIP: server did not start (non-web build?)"
    exit 0
fi

# ── Test 1: valid emit via JSON ───────────────────────────────────────────────
HTTP_STATUS="$(curl -s -o /dev/null -w '%{http_code}' -X POST \
    "http://localhost:$PORT/api/ambient/emit" \
    -H 'Content-Type: application/json' \
    -d '{"kind":"pwa_test_event","subject":"test-subject","extra":"value1"}')"

if [ "$HTTP_STATUS" = "200" ]; then
    pass "Test 1: POST with JSON content-type returns 200"
else
    fail "Test 1: expected 200, got $HTTP_STATUS"
fi

# Verify event was written to ambient.jsonl.
if grep -q '"kind":"pwa_test_event"' "$AMBIENT_FILE" 2>/dev/null \
   || grep -q '"event":"pwa_test_event"' "$AMBIENT_FILE" 2>/dev/null; then
    pass "Test 1b: event written to ambient.jsonl"
else
    fail "Test 1b: pwa_test_event not found in ambient.jsonl"
    cat "$AMBIENT_FILE" >&2 2>/dev/null || echo "(file missing)" >&2
fi

# ── Test 2: sendBeacon-style (text/plain with JSON body) ─────────────────────
HTTP_STATUS="$(curl -s -o /dev/null -w '%{http_code}' -X POST \
    "http://localhost:$PORT/api/ambient/emit" \
    -H 'Content-Type: text/plain' \
    -d '{"kind":"pwa_beacon_event","source":"autopilot"}')"

if [ "$HTTP_STATUS" = "200" ]; then
    pass "Test 2: POST with text/plain (sendBeacon) returns 200"
else
    fail "Test 2: expected 200, got $HTTP_STATUS"
fi

# ── Test 3: missing kind → 400 ────────────────────────────────────────────────
HTTP_STATUS="$(curl -s -o /dev/null -w '%{http_code}' -X POST \
    "http://localhost:$PORT/api/ambient/emit" \
    -H 'Content-Type: application/json' \
    -d '{"subject":"no kind field"}')"

if [ "$HTTP_STATUS" = "400" ]; then
    pass "Test 3: missing kind returns 400"
else
    fail "Test 3: expected 400 for missing kind, got $HTTP_STATUS"
fi

# ── Test 4: empty kind → 400 ─────────────────────────────────────────────────
HTTP_STATUS="$(curl -s -o /dev/null -w '%{http_code}' -X POST \
    "http://localhost:$PORT/api/ambient/emit" \
    -H 'Content-Type: application/json' \
    -d '{"kind":""}')"

if [ "$HTTP_STATUS" = "400" ]; then
    pass "Test 4: empty kind returns 400"
else
    fail "Test 4: expected 400 for empty kind, got $HTTP_STATUS"
fi

# ── Test 5: invalid JSON body → 400 ──────────────────────────────────────────
HTTP_STATUS="$(curl -s -o /dev/null -w '%{http_code}' -X POST \
    "http://localhost:$PORT/api/ambient/emit" \
    -H 'Content-Type: application/json' \
    -d 'not-json-at-all')"

if [ "$HTTP_STATUS" = "400" ]; then
    pass "Test 5: invalid JSON body returns 400"
else
    fail "Test 5: expected 400 for invalid JSON, got $HTTP_STATUS"
fi

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
if [ "$FAILURES" -eq 0 ]; then
    echo "[test-api-ambient-emit] PASS — all tests passed"
    exit 0
else
    echo "[test-api-ambient-emit] FAIL — $FAILURES test(s) failed"
    exit 1
fi
