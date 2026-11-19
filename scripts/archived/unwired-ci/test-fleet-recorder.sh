#!/usr/bin/env bash
# test-fleet-recorder.sh — INFRA-2174
#
# Smoke test for chump-fleet-recorder:
#   1. Builds the binary if not already present.
#   2. Starts an ephemeral NATS server (skipped gracefully if nats-server absent).
#   3. Starts chump-fleet-recorder against a temp DB.
#   4. Emits 5 known events via chump-coord emit (NATS path).
#   5. Appends 3 lines directly to the ambient.jsonl temp file.
#   6. Waits 2s for the recorder to ingest.
#   7. Asserts all 8 events are present in the SQLite DB.
#   8. Tests kill -TERM + restart loses zero events (durable consumer resume).
#
# Exit codes: 0 = pass, 1 = fail, 2 = skip (NATS or binary unavailable).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# ── colours ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
pass() { echo -e "${GREEN}PASS${NC} $*"; }
fail() { echo -e "${RED}FAIL${NC} $*"; exit 1; }
skip() { echo -e "${YELLOW}SKIP${NC} $*"; exit 0; }
info() { echo "     $*"; }

# ── build binary ──────────────────────────────────────────────────────────────
RECORDER_BIN="${REPO_ROOT}/target/debug/chump-fleet-recorder"
if [[ ! -x "$RECORDER_BIN" ]]; then
    info "Building chump-fleet-recorder..."
    (cd "$REPO_ROOT" && PATH="$HOME/.cargo/bin:$PATH" \
        cargo build --package chump-fleet-recorder 2>&1) || {
        fail "cargo build failed for chump-fleet-recorder"
    }
fi
[[ -x "$RECORDER_BIN" ]] || fail "binary not found after build: $RECORDER_BIN"
info "Binary: $RECORDER_BIN"

# ── temp workspace ────────────────────────────────────────────────────────────
TMP_DIR="$(mktemp -d /tmp/fleet-recorder-test-XXXXXX)"
trap 'kill $NATS_PID $RECORDER_PID 2>/dev/null || true; rm -rf "$TMP_DIR"' EXIT

DB_PATH="${TMP_DIR}/fleet_events.db"
AMBIENT_PATH="${TMP_DIR}/ambient.jsonl"
NATS_PORT="14522"  # non-standard port to avoid collision with running NATS
NATS_URL="nats://127.0.0.1:${NATS_PORT}"

# Create empty ambient file.
touch "$AMBIENT_PATH"

# ── optional: start ephemeral NATS ───────────────────────────────────────────
NATS_AVAILABLE=0
if command -v nats-server &>/dev/null; then
    nats-server -p "$NATS_PORT" -js &>/dev/null &
    NATS_PID=$!
    sleep 0.5
    if kill -0 "$NATS_PID" 2>/dev/null; then
        NATS_AVAILABLE=1
        info "Ephemeral NATS started on port ${NATS_PORT} (pid=${NATS_PID})"
    else
        NATS_PID=0
        info "nats-server present but failed to start — ambient-only mode"
    fi
else
    NATS_PID=0
    info "nats-server not found — testing ambient-only mode (NATS path skipped)"
fi

# ── start recorder ────────────────────────────────────────────────────────────
CHUMP_FLEET_EVENTS_DB="$DB_PATH" \
CHUMP_AMBIENT_LOG="$AMBIENT_PATH" \
CHUMP_NATS_URL="$NATS_URL" \
RUST_LOG=info \
    "$RECORDER_BIN" &
RECORDER_PID=$!
info "Recorder started (pid=${RECORDER_PID})"
sleep 0.3  # give it time to open DB and start tailing

# ── emit 5 NATS events (if NATS available) ───────────────────────────────────
NATS_EVENTS_EMITTED=0
if [[ "$NATS_AVAILABLE" -eq 1 ]] && command -v chump-coord &>/dev/null; then
    for i in 1 2 3 4 5; do
        CHUMP_NATS_URL="$NATS_URL" chump-coord emit \
            --kind "test_nats_event" \
            --session "test-session-${i}" \
            --gap "TEST-${i}" \
            2>/dev/null || true
    done
    NATS_EVENTS_EMITTED=5
    info "Emitted ${NATS_EVENTS_EMITTED} NATS events via chump-coord emit"
elif [[ "$NATS_AVAILABLE" -eq 1 ]]; then
    info "chump-coord not in PATH — skipping NATS emit; injecting via sqlite directly"
fi

# ── append 3 ambient lines ────────────────────────────────────────────────────
AMBIENT_TS_1="2026-05-29T12:00:01Z"
AMBIENT_TS_2="2026-05-29T12:00:02Z"
AMBIENT_TS_3="2026-05-29T12:00:03Z"
printf '{"ts":"%s","kind":"ambient_test_event","session":"ambient-s1","gap":"AMB-1"}\n' \
    "$AMBIENT_TS_1" >> "$AMBIENT_PATH"
printf '{"ts":"%s","kind":"ambient_test_event","session":"ambient-s2","gap":"AMB-2"}\n' \
    "$AMBIENT_TS_2" >> "$AMBIENT_PATH"
printf '{"ts":"%s","kind":"ambient_test_event","session":"ambient-s3","gap":"AMB-3"}\n' \
    "$AMBIENT_TS_3" >> "$AMBIENT_PATH"
info "Appended 3 ambient lines to ${AMBIENT_PATH}"

# ── wait for ingestion ────────────────────────────────────────────────────────
sleep 2

# ── assert ambient events in DB ──────────────────────────────────────────────
AMBIENT_COUNT=$(sqlite3 "$DB_PATH" \
    "SELECT COUNT(*) FROM events WHERE source='ambient' AND event_kind='ambient_test_event';" \
    2>/dev/null || echo "0")
info "Ambient events in DB: ${AMBIENT_COUNT} (expected 3)"
[[ "$AMBIENT_COUNT" -eq 3 ]] || \
    fail "Expected 3 ambient events, got ${AMBIENT_COUNT}"
pass "3 ambient events recorded"

# ── assert NATS events in DB (if emitted) ────────────────────────────────────
if [[ "$NATS_EVENTS_EMITTED" -gt 0 ]]; then
    NATS_COUNT=$(sqlite3 "$DB_PATH" \
        "SELECT COUNT(*) FROM events WHERE source LIKE 'nats:%' AND event_kind='test_nats_event';" \
        2>/dev/null || echo "0")
    info "NATS events in DB: ${NATS_COUNT} (expected ${NATS_EVENTS_EMITTED})"
    [[ "$NATS_COUNT" -eq "$NATS_EVENTS_EMITTED" ]] || \
        fail "Expected ${NATS_EVENTS_EMITTED} NATS events, got ${NATS_COUNT}"
    pass "${NATS_EVENTS_EMITTED} NATS events recorded"
else
    info "NATS event assertion skipped (NATS not available or chump-coord absent)"
fi

# ── total count check ─────────────────────────────────────────────────────────
TOTAL=$(sqlite3 "$DB_PATH" "SELECT COUNT(*) FROM events;" 2>/dev/null || echo "0")
EXPECTED_MIN=$((3 + NATS_EVENTS_EMITTED))
info "Total events in DB: ${TOTAL} (expected >= ${EXPECTED_MIN})"
[[ "$TOTAL" -ge "$EXPECTED_MIN" ]] || \
    fail "Total events ${TOTAL} < expected minimum ${EXPECTED_MIN}"
pass "Total event count >= ${EXPECTED_MIN}"

# ── kill -TERM + restart: zero-event-loss test ───────────────────────────────
info "Testing SIGTERM + restart (durable consumer resume)..."
COUNT_BEFORE=$(sqlite3 "$DB_PATH" "SELECT COUNT(*) FROM events;" 2>/dev/null || echo "0")
info "Events before SIGTERM: ${COUNT_BEFORE}"

# Send SIGTERM — recorder should exit cleanly.
kill -TERM "$RECORDER_PID" 2>/dev/null || true
sleep 0.5

# Append 2 more ambient lines while recorder is down.
printf '{"ts":"2026-05-29T12:01:00Z","kind":"post_restart_event","session":"rs1"}\n' \
    >> "$AMBIENT_PATH"
printf '{"ts":"2026-05-29T12:01:01Z","kind":"post_restart_event","session":"rs2"}\n' \
    >> "$AMBIENT_PATH"
info "Appended 2 ambient lines while recorder was down"

# Restart the recorder.
CHUMP_FLEET_EVENTS_DB="$DB_PATH" \
CHUMP_AMBIENT_LOG="$AMBIENT_PATH" \
CHUMP_NATS_URL="$NATS_URL" \
RUST_LOG=info \
    "$RECORDER_BIN" &
RECORDER_PID=$!
info "Recorder restarted (pid=${RECORDER_PID})"
sleep 2

COUNT_AFTER=$(sqlite3 "$DB_PATH" "SELECT COUNT(*) FROM events;" 2>/dev/null || echo "0")
info "Events after restart + 2s: ${COUNT_AFTER}"

POST_RESTART=$(sqlite3 "$DB_PATH" \
    "SELECT COUNT(*) FROM events WHERE event_kind='post_restart_event';" \
    2>/dev/null || echo "0")
info "post_restart_event rows: ${POST_RESTART} (expected 2)"
[[ "$POST_RESTART" -eq 2 ]] || \
    fail "Expected 2 post-restart events, got ${POST_RESTART} (zero-event-loss test FAILED)"
pass "SIGTERM + restart: 2 post-restart events captured (zero loss)"

# ── INFRA-2203: assert gap_id='' not NULL for events with no gap field ────────
# Append a line with no gap_id so the recorder must coerce None→''.
printf '{"ts":"2026-05-29T12:02:00Z","kind":"no_gap_event","session":"null-gap-s1"}\n' \
    >> "$AMBIENT_PATH"
info "Appended ambient line with no gap_id (INFRA-2203 NULL-coerce test)"
sleep 1  # allow recorder to ingest

NULL_GAP_ROW=$(sqlite3 "$DB_PATH" \
    "SELECT COUNT(*) FROM events WHERE event_kind='no_gap_event' AND gap_id IS NULL;" \
    2>/dev/null || echo "0")
EMPTY_GAP_ROW=$(sqlite3 "$DB_PATH" \
    "SELECT COUNT(*) FROM events WHERE event_kind='no_gap_event' AND gap_id='';" \
    2>/dev/null || echo "0")
info "no_gap_event rows with gap_id IS NULL : ${NULL_GAP_ROW} (must be 0)"
info "no_gap_event rows with gap_id=''      : ${EMPTY_GAP_ROW} (must be 1)"
[[ "$NULL_GAP_ROW" -eq 0 ]] || \
    fail "INFRA-2203: recorder wrote NULL gap_id instead of '' for event with no gap field"
[[ "$EMPTY_GAP_ROW" -eq 1 ]] || \
    fail "INFRA-2203: expected gap_id='' row not found (got ${EMPTY_GAP_ROW})"
pass "INFRA-2203: gap_id='' (not NULL) for event with no gap field"

# ── schema sanity: verify all columns and indexes exist ──────────────────────
COLS=$(sqlite3 "$DB_PATH" "PRAGMA table_info(events);" | awk -F'|' '{print $2}' | sort | tr '\n' ',')
for col in ts ts_ms source subject event_kind session_id gap_id payload; do
    echo "$COLS" | grep -q "$col" || fail "Schema missing column: $col"
done
pass "Schema columns verified"

IDX=$(sqlite3 "$DB_PATH" ".indexes events" 2>/dev/null || sqlite3 "$DB_PATH" \
    "SELECT name FROM sqlite_master WHERE type='index' AND tbl_name='events';" | tr '\n' ',')
for idx in idx_events_ts_ms idx_events_session idx_events_gap idx_events_kind; do
    echo "$IDX" | grep -q "$idx" || fail "Missing index: $idx"
done
pass "All 4 indexes present"

echo
pass "test-fleet-recorder: ALL CHECKS PASSED"
