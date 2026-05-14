#!/usr/bin/env bash
# INFRA-991: end-to-end test for the fleet_auth_fallback event stream that
# feeds the PWA auth-toast component.
#
# Verifies:
#   - /api/ambient/stream?kind=fleet_auth_fallback only delivers events
#     whose kind matches (server-side filter)
#   - A line written to .chump-locks/ambient.jsonl after server start is
#     picked up by the live-tail loop and streamed within ~3s (AC #5)
#   - The event body contains the failed_mode + fallback_mode fields that
#     the toast component renders
#   - Unrelated events (other kinds) are NOT included in the filtered stream

set -euo pipefail

PORT="${CHUMP_TEST_PORT:-38960}"
WORK=$(mktemp -d /tmp/chump-pwa-auth-toast-test.XXXXXX)
trap 'cleanup' EXIT

cleanup() {
    [[ -n "${WEB_PID:-}" ]] && kill "$WEB_PID" 2>/dev/null || true
    [[ -n "${WEB_PID:-}" ]] && wait "$WEB_PID" 2>/dev/null || true
    rm -rf "$WORK"
}

BIN="${CHUMP_BIN:-/private/tmp/chump-infra-991/target/debug/chump}"
if [[ ! -x "$BIN" ]]; then
    echo "[test] FAIL: chump binary not found at $BIN — build first with cargo build --bin chump" >&2
    exit 2
fi

mkdir -p "$WORK/.chump-locks"
AMBIENT="$WORK/.chump-locks/ambient.jsonl"

# Seed an unrelated event BEFORE server start so the seed-50 phase can
# decide whether to drop it.
SEED_TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
printf '{"ts":"%s","kind":"pwa_setting_changed","key":"x","value":"y","source_before":""}\n' "$SEED_TS" >> "$AMBIENT"

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
    echo "[test] FAIL: server did not become ready" >&2
    tail -30 "$WORK/srv.log" >&2
    exit 1
fi
echo "[test] server up on :$PORT"

# Start a curl SSE consumer in the background. -N disables buffering;
# the timeout caps the test runtime. Output captured to a file.
SSE_OUT="$WORK/sse.out"
( curl -sN --max-time 6 "http://localhost:$PORT/api/ambient/stream?kind=fleet_auth_fallback" >"$SSE_OUT" 2>&1 ) &
SSE_PID=$!

# Give the SSE consumer a moment to connect + seed.
sleep 1

# Append a fleet_auth_fallback event — should arrive within ~500ms tail loop.
LIVE_TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
printf '{"ts":"%s","kind":"fleet_auth_fallback","failed_mode":"api-key","fallback_mode":"oauth"}\n' "$LIVE_TS" >> "$AMBIENT"

# Wait for the SSE consumer to finish (--max-time triggers exit).
wait "$SSE_PID" 2>/dev/null || true

# ── 1. live event was streamed ──
if ! grep -q 'fleet_auth_fallback' "$SSE_OUT"; then
    echo "[test] FAIL: live fleet_auth_fallback not in stream output" >&2
    head -40 "$SSE_OUT" >&2
    exit 1
fi
echo "[test] PASS: live fleet_auth_fallback event was streamed"

# ── 2. event body carries failed_mode + fallback_mode ──
if ! grep -q '"failed_mode":"api-key"' "$SSE_OUT" || \
   ! grep -q '"fallback_mode":"oauth"' "$SSE_OUT"; then
    echo "[test] FAIL: event body missing failed_mode or fallback_mode fields" >&2
    head -40 "$SSE_OUT" >&2
    exit 1
fi
echo "[test] PASS: event body carries failed_mode + fallback_mode"

# ── 3. unrelated kinds NOT in filtered stream ──
if grep -q 'pwa_setting_changed' "$SSE_OUT"; then
    echo "[test] FAIL: filtered stream leaked an unrelated kind (pwa_setting_changed)" >&2
    head -40 "$SSE_OUT" >&2
    exit 1
fi
echo "[test] PASS: server-side kind filter excludes unrelated events"

# ── 4. SSE framing: 'event: ambient' wrapper ──
if ! grep -q 'event: ambient' "$SSE_OUT" && ! grep -q 'event:ambient' "$SSE_OUT"; then
    echo "[test] FAIL: stream is missing the 'event: ambient' framing line" >&2
    head -40 "$SSE_OUT" >&2
    exit 1
fi
echo "[test] PASS: SSE framing present"

echo ""
echo "[test] ALL AUTH-TOAST STREAM CHECKS PASSED — INFRA-991 endpoint verified end-to-end"
