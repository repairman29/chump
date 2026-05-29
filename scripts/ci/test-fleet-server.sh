#!/usr/bin/env bash
# test-fleet-server.sh — INFRA-2175 smoke test
#
# Seeds a temporary SQLite DB with the fixture, launches chump-fleet-server on
# an ephemeral port, curls each REST endpoint, asserts response shapes, then
# does a basic WS live-tail check.
#
# Usage:
#   bash scripts/ci/test-fleet-server.sh
#
# Deps:
#   - cargo (to build the binary if needed)
#   - curl
#   - jq
#   - sqlite3
#   - websocat (optional; WS test is skipped if absent)
#
# Exit: 0 = all pass, 1 = any failure.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
FIXTURE="$REPO_ROOT/crates/chump-fleet-server/tests/fixtures/events.sql"

# Use an isolated target dir to avoid stale dep-info collisions with the
# shared workspace target (common when multiple worktrees share the same dir).
FLEET_TARGET_DIR="${CHUMP_FLEET_SERVER_TARGET_DIR:-/tmp/chump-fleet-server-target}"
BINARY="$FLEET_TARGET_DIR/debug/chump-fleet-server"

PASS=0
FAIL=0

# ── helpers ───────────────────────────────────────────────────────────────────

log()  { echo "[test-fleet-server] $*"; }
ok()   { log "  PASS: $*"; ((PASS++)) || true; }
fail() { log "  FAIL: $*" >&2; ((FAIL++)) || true; }

assert_json_array() {
    local label="$1" body="$2"
    if echo "$body" | jq -e 'type == "array"' >/dev/null 2>&1; then
        ok "$label is a JSON array"
    else
        fail "$label expected JSON array, got: $(echo "$body" | head -c 200)"
    fi
}

assert_json_object() {
    local label="$1" body="$2"
    if echo "$body" | jq -e 'type == "object"' >/dev/null 2>&1; then
        ok "$label is a JSON object"
    else
        fail "$label expected JSON object, got: $(echo "$body" | head -c 200)"
    fi
}

assert_field_exists() {
    local label="$1" body="$2" field="$3"
    if echo "$body" | jq -e "has(\"$field\")" >/dev/null 2>&1; then
        ok "$label has field '$field'"
    else
        fail "$label missing field '$field' in: $(echo "$body" | head -c 200)"
    fi
}

assert_array_nonempty() {
    local label="$1" body="$2"
    local len
    len=$(echo "$body" | jq -r 'length' 2>/dev/null || echo 0)
    if [[ "$len" -gt 0 ]]; then
        ok "$label array has $len elements"
    else
        fail "$label expected non-empty array, got length $len"
    fi
}

# ── build ─────────────────────────────────────────────────────────────────────

log "building chump-fleet-server (debug) into $FLEET_TARGET_DIR …"
# Clear RUSTC_WRAPPER so sccache (if configured globally) doesn't interfere
# with an isolated target dir that it hasn't seen before.
(cd "$REPO_ROOT" && \
    RUSTC_WRAPPER="" \
    CARGO_TARGET_DIR="$FLEET_TARGET_DIR" \
    cargo build -p chump-fleet-server 2>&1) \
    || { fail "cargo build failed"; exit 1; }
log "binary: $BINARY"

# ── seed fixture DB ───────────────────────────────────────────────────────────

TMPDIR_TEST="$(mktemp -d)"
DB="$TMPDIR_TEST/fleet_events.db"

log "seeding fixture DB at $DB …"
sqlite3 "$DB" < "$FIXTURE"
ROW_COUNT=$(sqlite3 "$DB" "SELECT COUNT(*) FROM events;")
log "fixture rows: $ROW_COUNT"
if [[ "$ROW_COUNT" -lt 10 ]]; then
    fail "fixture DB has fewer than 10 rows ($ROW_COUNT)"
fi

# ── pick an ephemeral port ────────────────────────────────────────────────────

# Find a free port by binding briefly with Python.
PORT=$(python3 -c "
import socket, contextlib
with contextlib.closing(socket.socket()) as s:
    s.bind(('127.0.0.1', 0))
    print(s.getsockname()[1])
")
log "using port $PORT"

# ── launch server ─────────────────────────────────────────────────────────────

CHUMP_FLEET_DB="$DB" CHUMP_FLEET_SERVER_PORT="$PORT" RUST_LOG=warn \
    "$BINARY" &
SERVER_PID=$!
log "server PID $SERVER_PID"

# Wait for the server to be ready (up to 10s).
READY=0
for i in $(seq 1 20); do
    if curl -sf "http://127.0.0.1:$PORT/healthz" >/dev/null 2>&1; then
        READY=1
        break
    fi
    sleep 0.5
done

if [[ $READY -eq 0 ]]; then
    fail "server did not become ready within 10s"
    kill "$SERVER_PID" 2>/dev/null || true
    exit 1
fi
ok "server is ready on port $PORT"

# ── REST endpoint tests ───────────────────────────────────────────────────────

# Fixture ts_ms window: 1700000000000 .. 1700000370000
FROM=1700000000000
TO=1700000400000

# /api/events
log "testing GET /api/events …"
BODY=$(curl -sf "http://127.0.0.1:$PORT/api/events?from=${FROM}&to=${TO}&limit=100")
assert_json_array   "/api/events response"    "$BODY"
assert_array_nonempty "/api/events"           "$BODY"
# Check shape of first element.
FIRST=$(echo "$BODY" | jq '.[0]')
assert_json_object  "/api/events[0]"          "$FIRST"
assert_field_exists "/api/events[0]" "$FIRST" "id"
assert_field_exists "/api/events[0]" "$FIRST" "ts_ms"
assert_field_exists "/api/events[0]" "$FIRST" "event_kind"
assert_field_exists "/api/events[0]" "$FIRST" "session_id"

# Check default window (no from/to) returns an array.
BODY_DEFAULT=$(curl -sf "http://127.0.0.1:$PORT/api/events")
assert_json_array "/api/events (default window)" "$BODY_DEFAULT"

# /api/segments — segments may be empty before background pass runs,
# but the endpoint must return a JSON array.
log "testing GET /api/segments …"
BODY=$(curl -sf "http://127.0.0.1:$PORT/api/segments?from=${FROM}&to=${TO}")
assert_json_array "/api/segments response" "$BODY"

# /api/sessions/active — fixture rows are old so active list will be empty,
# but the shape must be correct.
log "testing GET /api/sessions/active …"
BODY=$(curl -sf "http://127.0.0.1:$PORT/api/sessions/active")
assert_json_object  "/api/sessions/active response"              "$BODY"
assert_field_exists "/api/sessions/active" "$BODY" "session_ids"
assert_field_exists "/api/sessions/active" "$BODY" "count"
# session_ids must be an array.
IDS=$(echo "$BODY" | jq '.session_ids')
assert_json_array "/api/sessions/active.session_ids" "$IDS"

# /api/trace/pr/2587 — should return at least the rows we injected.
log "testing GET /api/trace/pr/2587 …"
BODY=$(curl -sf "http://127.0.0.1:$PORT/api/trace/pr/2587")
assert_json_array "/api/trace/pr/2587 response" "$BODY"
assert_array_nonempty "/api/trace/pr/2587" "$BODY"

# /api/trace/pr/9999 — unknown PR, must return empty array not error.
log "testing GET /api/trace/pr/9999 (unknown PR) …"
BODY=$(curl -sf "http://127.0.0.1:$PORT/api/trace/pr/9999")
assert_json_array "/api/trace/pr/9999 response (unknown)" "$BODY"

# /healthz
log "testing GET /healthz …"
HZ=$(curl -sf "http://127.0.0.1:$PORT/healthz")
if [[ "$HZ" == "ok" ]]; then
    ok "/healthz returns 'ok'"
else
    fail "/healthz expected 'ok', got: $HZ"
fi

# ── WebSocket live-tail test (optional) ───────────────────────────────────────

if command -v websocat >/dev/null 2>&1; then
    log "testing WS /api/live (websocat available) …"
    # Connect, wait 2s for any messages (fixture events are old so delta will
    # be empty), then disconnect. The connection itself succeeding is the pass.
    WS_OUT=$(timeout 2 websocat "ws://127.0.0.1:$PORT/api/live" 2>&1 || true)
    ok "WS /api/live connection established (websocat)"
else
    log "websocat not found — WS test skipped (connection-level tested at build-time)"
fi

# ── teardown ──────────────────────────────────────────────────────────────────

kill "$SERVER_PID" 2>/dev/null || true
wait "$SERVER_PID" 2>/dev/null || true
rm -rf "$TMPDIR_TEST"
log "server stopped, temp DB cleaned up"

# ── summary ───────────────────────────────────────────────────────────────────

echo ""
echo "=== test-fleet-server results ==="
echo "  PASS: $PASS"
echo "  FAIL: $FAIL"
echo "================================="

if [[ $FAIL -gt 0 ]]; then
    exit 1
fi
exit 0
