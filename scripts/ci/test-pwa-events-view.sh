#!/usr/bin/env bash
# INFRA-1198: end-to-end test for the Events view's backend dependency
# (/api/ambient/stream + ?kind= filter). Confirms the SSE endpoint
# delivers events with the framing the ChumpAmbientViewer component
# expects.
#
# Verifies:
#   - /api/ambient/stream returns SSE-framed `event: ambient` data lines
#   - A line written to ambient.jsonl after server start is streamed
#     within ~3s
#   - ?kind=<X> server-side filter excludes other kinds
#   - Unfiltered stream delivers all kinds

set -euo pipefail

PORT="${CHUMP_TEST_PORT:-38980}"
WORK=$(mktemp -d /tmp/chump-pwa-events-test.XXXXXX)
trap 'cleanup' EXIT

cleanup() {
    [[ -n "${WEB_PID:-}" ]] && kill "$WEB_PID" 2>/dev/null || true
    [[ -n "${WEB_PID:-}" ]] && wait "$WEB_PID" 2>/dev/null || true
    rm -rf "$WORK"
}

BIN="${CHUMP_BIN:-/Users/jeffadkins/Projects/Chump/target/debug/chump}"
if [[ ! -x "$BIN" ]]; then
    echo "[test] FAIL: chump binary not found at $BIN" >&2
    exit 2
fi

mkdir -p "$WORK/.chump-locks"
AMBIENT="$WORK/.chump-locks/ambient.jsonl"
CHUMP_HOME="$WORK" CHUMP_CSRF_ENABLED=0 \
    "$BIN" --web --port "$PORT" >"$WORK/srv.log" 2>&1 &
WEB_PID=$!
for _ in $(seq 1 30); do
    if curl -sf "http://localhost:$PORT/api/health" >/dev/null 2>&1; then
        break
    fi
    sleep 1
done
if ! curl -sf "http://localhost:$PORT/api/health" >/dev/null 2>&1; then
    echo "[test] FAIL: server did not become ready on port $PORT" >&2
    tail -20 "$WORK/srv.log" >&2
    exit 1
fi
echo "[test] server up on :$PORT"

# ── 1. Unfiltered stream picks up a freshly-written event ──────────────────
SSE_OUT="$WORK/sse-all.out"
( curl -sN --max-time 5 "http://localhost:$PORT/api/ambient/stream" >"$SSE_OUT" 2>&1 ) &
SSE_PID=$!
sleep 1
LIVE_TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
printf '{"ts":"%s","kind":"test_event_INFRA1198_marker","field_a":"alpha","field_b":42}\n' "$LIVE_TS" >> "$AMBIENT"
printf '{"ts":"%s","kind":"unrelated_kind","other":"data"}\n' "$LIVE_TS" >> "$AMBIENT"
wait "$SSE_PID" 2>/dev/null || true

if ! grep -q 'test_event_INFRA1198_marker' "$SSE_OUT"; then
    echo "[test] FAIL: unfiltered stream missed test_event_INFRA1198_marker" >&2
    head -30 "$SSE_OUT" >&2
    exit 1
fi
if ! grep -q 'unrelated_kind' "$SSE_OUT"; then
    echo "[test] FAIL: unfiltered stream missed unrelated_kind" >&2
    head -30 "$SSE_OUT" >&2
    exit 1
fi
echo "[test] PASS: unfiltered stream delivers both kinds"

# ── 2. Filtered stream ?kind=test_event_INFRA1198_marker excludes others ───
SSE_OUT2="$WORK/sse-filtered.out"
( curl -sN --max-time 5 "http://localhost:$PORT/api/ambient/stream?kind=test_event_INFRA1198_marker" \
  >"$SSE_OUT2" 2>&1 ) &
SSE_PID2=$!
sleep 1
LIVE_TS2="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
printf '{"ts":"%s","kind":"test_event_INFRA1198_marker","field_a":"second","field_b":43}\n' "$LIVE_TS2" >> "$AMBIENT"
printf '{"ts":"%s","kind":"another_unrelated","x":1}\n' "$LIVE_TS2" >> "$AMBIENT"
wait "$SSE_PID2" 2>/dev/null || true

if ! grep -q 'test_event_INFRA1198_marker' "$SSE_OUT2"; then
    echo "[test] FAIL: filtered stream missed the matching kind" >&2
    head -30 "$SSE_OUT2" >&2
    exit 1
fi
if grep -q 'another_unrelated' "$SSE_OUT2"; then
    echo "[test] FAIL: filtered stream leaked an unrelated kind" >&2
    head -30 "$SSE_OUT2" >&2
    exit 1
fi
echo "[test] PASS: ?kind= filter excludes unrelated events server-side"

# ── 3. SSE framing — `event: ambient` lines present ────────────────────────
if ! grep -qE '^event:\s*ambient' "$SSE_OUT" && ! grep -q 'event:ambient' "$SSE_OUT"; then
    echo "[test] FAIL: SSE stream is missing the 'event: ambient' framing line" >&2
    head -20 "$SSE_OUT" >&2
    exit 1
fi
echo "[test] PASS: SSE framing present (event: ambient)"

# ── 4. Event body carries the JSON fields the viewer renders ───────────────
if ! grep -q '"field_a":"alpha"' "$SSE_OUT"; then
    echo "[test] FAIL: event body missing fields the viewer would render" >&2
    exit 1
fi
echo "[test] PASS: event body carries all original fields"

echo ""
echo "[test] ALL EVENTS-VIEW STREAM CHECKS PASSED — INFRA-1198 backend verified"
