#!/usr/bin/env bash
# test-pwa-sse-consumer.sh — PRODUCT-099 tests.
#
# Verifies the PWA frontend consumes /api/dashboard/stream SSE instead of
# polling, including reconnect, visibility-pause, and replay-to-late-subscribers.
#
# Run modes:
#   bash scripts/ci/test-pwa-sse-consumer.sh        # source audit only
#   CHUMP_BIN=${CARGO_TARGET_DIR:-./target}/debug/chump bash …           # adds live HTTP smoke

set -uo pipefail

PASS=0
FAIL=0
FAILS=()

ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); FAILS+=("$1"); }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
APP_JS="$REPO_ROOT/web/v2/app.js"
WS="$REPO_ROOT/src/web_server.rs"

echo "=== PRODUCT-099 PWA SSE consumer tests ==="
echo

# ── (a) Source audit: app.js wires DashboardStream singleton ─────────────────
echo "--- Tests 1-7: app.js DashboardStream singleton ---"

[[ -f "$APP_JS" ]] || { fail "Test 1: web/v2/app.js missing"; echo; echo "FAIL"; exit 1; }
ok "Test 1: web/v2/app.js present"

if grep -q 'class DashboardStream' "$APP_JS"; then
    ok "Test 2: DashboardStream class defined"
else
    fail "Test 2: DashboardStream class missing"
fi

if grep -q "new EventSource(.*'/api/dashboard/stream'" "$APP_JS" \
   || grep -q 'new EventSource(.*"/api/dashboard/stream"' "$APP_JS"; then
    ok "Test 3: EventSource opens /api/dashboard/stream"
else
    fail "Test 3: EventSource for /api/dashboard/stream not found"
fi

if grep -q "addEventListener('dashboard'" "$APP_JS" \
   || grep -q 'addEventListener("dashboard"' "$APP_JS"; then
    ok "Test 4: subscribes to 'dashboard' event name"
else
    fail "Test 4: 'dashboard' event listener missing"
fi

if grep -q 'visibilitychange' "$APP_JS"; then
    ok "Test 5: visibilitychange handler wired (battery-aware pause)"
else
    fail "Test 5: visibilitychange handler missing"
fi

if grep -qE "addEventListener\(('online'|\"online\")" "$APP_JS" \
   && grep -qE "addEventListener\(('offline'|\"offline\")" "$APP_JS"; then
    ok "Test 6: online + offline handlers wired"
else
    fail "Test 6: online/offline handlers missing"
fi

# Reconnect with jitter/backoff
if grep -qE '(reconnectDelay|reconnect_delay|backoff)' "$APP_JS" \
   && grep -q 'Math.random' "$APP_JS"; then
    ok "Test 7: reconnect backoff with jitter present"
else
    fail "Test 7: reconnect backoff with jitter missing"
fi

# ── (b) Source audit: late-subscriber replay ──────────────────────────────────
echo "--- Test 8: replay-to-late-subscriber pattern ---"
if grep -qE '(#lastPayload|lastPayload)' "$APP_JS"; then
    ok "Test 8: stream caches last payload for late subscribers"
else
    fail "Test 8: lastPayload replay missing (race: late-mount components stay 'init')"
fi

# ── (c) Source audit: pill / status UI ────────────────────────────────────────
echo "--- Tests 9-10: live status indicator ---"
if grep -qE '(chump:stream-status|stream-pill)' "$APP_JS"; then
    ok "Test 9: stream status event/pill wired to UI"
else
    fail "Test 9: stream status pill/event missing"
fi

if grep -qE "'(live|connecting|reconnecting|paused|offline)'" "$APP_JS"; then
    ok "Test 10: status state strings present"
else
    fail "Test 10: status state strings missing"
fi

# ── (d) Backend SSE endpoint still exists ─────────────────────────────────────
echo "--- Test 11: backend /api/dashboard/stream endpoint present ---"
if [[ -f "$WS" ]] && grep -q 'handle_dashboard_stream' "$WS"; then
    ok "Test 11: web_server.rs exposes handle_dashboard_stream"
else
    fail "Test 11: handle_dashboard_stream missing from web_server.rs"
fi

# ── (e) Live HTTP smoke (optional — needs binary) ─────────────────────────────
if [[ -n "${CHUMP_BIN:-}" && -x "${CHUMP_BIN}" ]]; then
    echo "--- Test 12: live SSE smoke ---"
    PORT="${CHUMP_TEST_PORT:-3911}"
    LOG=$(mktemp)
    "${CHUMP_BIN}" --web --port "$PORT" >"$LOG" 2>&1 &
    PID=$!
    trap 'kill "$PID" 2>/dev/null || true; rm -f "$LOG"' EXIT

    # Wait for server up
    for _ in $(seq 1 30); do
        if curl -sf "http://127.0.0.1:$PORT/" >/dev/null 2>&1; then break; fi
        sleep 0.2
    done

    # Pull first SSE chunk with a 6s budget — handle_dashboard_stream emits
    # immediately on connect, before the 30s loop sleep, so we should see
    # `event: dashboard` within ~1s.
    OUT=$(curl -sN --max-time 6 "http://127.0.0.1:$PORT/api/dashboard/stream" \
            | head -c 4096 || true)

    if printf '%s' "$OUT" | grep -q '^event: dashboard'; then
        ok "Test 12a: SSE emits 'event: dashboard'"
    else
        fail "Test 12a: no 'event: dashboard' frame within 6s"
    fi

    if printf '%s' "$OUT" | grep -q '^data: {'; then
        ok "Test 12b: SSE data line is JSON object"
    else
        fail "Test 12b: SSE data line not JSON object"
    fi

    kill "$PID" 2>/dev/null || true
    trap - EXIT
    rm -f "$LOG"
else
    echo "--- Test 12: live SSE smoke (SKIPPED — set CHUMP_BIN=path/to/chump to run) ---"
fi

echo
echo "=== Summary: $PASS passed, $FAIL failed ==="
if (( FAIL > 0 )); then
    printf 'FAILS:\n'
    for f in "${FAILS[@]}"; do printf '  - %s\n' "$f"; done
    exit 1
fi
echo "PASS"
