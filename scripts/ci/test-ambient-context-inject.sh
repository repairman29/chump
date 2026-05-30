#!/usr/bin/env bash
# scripts/ci/test-ambient-context-inject.sh — smoke tests for ambient-context-inject.sh
#
# Covers INFRA-2262 AC#5: synth ambient.jsonl with relevant events, run
# --tick-preamble, assert digest line present + cursor updated.
#
# Also smoke-tests the existing SessionStart/PreToolUse modes to catch
# regressions in the main hook path.
#
# Exit 0 = all tests pass. Exit 1 = failure (test name printed to stderr).

set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
SCRIPT="$REPO_ROOT/scripts/coord/ambient-context-inject.sh"

PASS=0
FAIL=0

_pass() { echo "  PASS: $1"; PASS=$(( PASS + 1 )); }
_fail() { echo "  FAIL: $1" >&2; FAIL=$(( FAIL + 1 )); }

# ── Setup: temp dir per test run ──────────────────────────────────────────────
WORK_DIR="$(mktemp -d /tmp/test-aci-XXXXXX)"
trap 'rm -rf "$WORK_DIR"' EXIT

# When CHUMP_AMBIENT_LOG is set, ambient-context-inject.sh derives LOCK_DIR
# from the ambient log's parent directory. So cursor files and autopilot-logs
# live alongside ambient.jsonl — use WORK_DIR directly as "LOCK_DIR".
LOCK_DIR="$WORK_DIR"
mkdir -p "$LOCK_DIR/autopilot-logs"

AMBIENT_LOG="$LOCK_DIR/ambient.jsonl"

# ── Helper: write a synthetic ambient event ───────────────────────────────────
_write_event() {
    local kind="$1"
    local extra="${2:-}"
    local ts
    ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    if [[ -n "$extra" ]]; then
        printf '{"ts":"%s","kind":"%s",%s}\n' "$ts" "$kind" "$extra" >> "$AMBIENT_LOG"
    else
        printf '{"ts":"%s","kind":"%s"}\n' "$ts" "$kind" >> "$AMBIENT_LOG"
    fi
}

# ── Test 1: --tick-preamble with no ambient log exits 0 (noop) ───────────────
echo ""
echo "=== Test 1: tick-preamble with missing ambient log ==="
rm -f "$AMBIENT_LOG"
if CHUMP_AMBIENT_LOG="$AMBIENT_LOG" \
       bash "$SCRIPT" --tick-preamble --role test-role 2>/dev/null; then
    _pass "exits 0 when ambient log missing"
else
    _fail "should exit 0 when ambient log missing"
fi

# ── Test 2: --tick-preamble with no relevant events prints no-events line ─────
echo ""
echo "=== Test 2: tick-preamble with no relevant events ==="
_write_event "commit" '"session":"other","sha":"abc123","gap":"INFRA-001","msg":"test"'
_write_event "session_start" '"session":"other-session"'

OUTPUT="$(CHUMP_AMBIENT_LOG="$AMBIENT_LOG" \
    bash "$SCRIPT" --tick-preamble --role test-role 2>/dev/null || true)"

if echo "$OUTPUT" | grep -q "no new relevant events"; then
    _pass "prints no-events marker when no FEEDBACK/WARN/STUCK/DONE/INTENT events"
else
    _fail "expected 'no new relevant events' marker, got: $OUTPUT"
fi

# ── Test 3: cursor file created after read ────────────────────────────────────
echo ""
echo "=== Test 3: cursor file created ==="
# LOCK_DIR = WORK_DIR = dirname(AMBIENT_LOG), so cursor lives at $LOCK_DIR/<role>-ambient-cursor
CURSOR_FILE="$LOCK_DIR/test-role-ambient-cursor"
rm -f "$CURSOR_FILE"

CHUMP_AMBIENT_LOG="$AMBIENT_LOG" \
    bash "$SCRIPT" --tick-preamble --role test-role 2>/dev/null || true

if [[ -f "$CURSOR_FILE" ]]; then
    _pass "cursor file created at $CURSOR_FILE"
else
    _fail "cursor file not created at $CURSOR_FILE"
fi

# ── Test 4: relevant FEEDBACK event appears in digest ─────────────────────────
echo ""
echo "=== Test 4: FEEDBACK event appears in digest ==="
# Write a FEEDBACK event after current cursor position
CURSOR_VAL="$(cat "$CURSOR_FILE" 2>/dev/null || echo 0)"
_write_event "FEEDBACK" '"session":"orchestrator","note":"please fix the fleet-wire deafness"'

OUTPUT="$(CHUMP_AMBIENT_LOG="$AMBIENT_LOG" \
    bash "$SCRIPT" --tick-preamble --role test-role 2>/dev/null || true)"

if echo "$OUTPUT" | grep -q "FEEDBACK"; then
    _pass "FEEDBACK event appears in digest"
else
    _fail "FEEDBACK event missing from digest; output: $OUTPUT"
fi

# ── Test 5: cursor advances after second read (no replay) ────────────────────
echo ""
echo "=== Test 5: cursor advances — no event replay ==="
# CURSOR_FILE is set from Test 3 above; re-read current value
CURSOR_BEFORE="$(cat "$CURSOR_FILE" 2>/dev/null || echo 0)"

# Add another irrelevant event to advance line count
_write_event "commit" '"session":"other","sha":"def456","gap":"INFRA-002"'

CHUMP_AMBIENT_LOG="$AMBIENT_LOG" \
    bash "$SCRIPT" --tick-preamble --role test-role 2>/dev/null || true

CURSOR_AFTER="$(cat "$CURSOR_FILE" 2>/dev/null || echo 0)"

if [[ "$CURSOR_AFTER" -gt "$CURSOR_BEFORE" ]]; then
    _pass "cursor advanced from $CURSOR_BEFORE to $CURSOR_AFTER"
else
    _fail "cursor did not advance: before=$CURSOR_BEFORE after=$CURSOR_AFTER"
fi

# ── Test 6: second read no longer replays the consumed FEEDBACK event ─────────
echo ""
echo "=== Test 6: second read does not replay old FEEDBACK event ==="
# Cursor is now past the FEEDBACK event — a fresh read should not show it again
OUTPUT="$(CHUMP_AMBIENT_LOG="$AMBIENT_LOG" \
    bash "$SCRIPT" --tick-preamble --role test-role 2>/dev/null || true)"

if echo "$OUTPUT" | grep -q "no new relevant events"; then
    _pass "no replay of already-consumed FEEDBACK event"
else
    _fail "old FEEDBACK replayed on second read; output: $OUTPUT"
fi

# ── Test 7: WARN, STUCK, DONE, INTENT also trigger digest ────────────────────
echo ""
echo "=== Test 7: WARN / STUCK / DONE / INTENT are relevant kinds ==="
for kind in WARN STUCK DONE INTENT; do
    SYNTH_DIR="$WORK_DIR/synth-$kind"
    mkdir -p "$SYNTH_DIR/autopilot-logs"
    SYNTH_LOG="$SYNTH_DIR/ambient.jsonl"
    printf '{"ts":"2026-05-30T00:00:00Z","kind":"%s","note":"test event"}\n' "$kind" > "$SYNTH_LOG"

    OUT="$(CHUMP_AMBIENT_LOG="$SYNTH_LOG" \
        bash "$SCRIPT" --tick-preamble --role "kind-test-$kind" 2>/dev/null || true)"

    if echo "$OUT" | grep -q "$kind"; then
        _pass "kind=$kind appears in digest"
    else
        _fail "kind=$kind missing from digest; output: $OUT"
    fi
done

# ── Test 8: feedback_fanout_delivered with recipient_count > 0 is relevant ───
echo ""
echo "=== Test 8: feedback_fanout_delivered with recipients is relevant ==="
FANOUT_DIR="$WORK_DIR/fanout"
mkdir -p "$FANOUT_DIR/autopilot-logs"
FANOUT_LOG="$FANOUT_DIR/ambient.jsonl"
printf '{"ts":"2026-05-30T00:00:00Z","kind":"feedback_fanout_delivered","recipient_count":3,"note":"fanout to 3"}\n' > "$FANOUT_LOG"

OUT="$(CHUMP_AMBIENT_LOG="$FANOUT_LOG" \
    bash "$SCRIPT" --tick-preamble --role fanout-test 2>/dev/null || true)"

if echo "$OUT" | grep -q "feedback_fanout_delivered"; then
    _pass "feedback_fanout_delivered with recipient_count>0 appears in digest"
else
    _fail "feedback_fanout_delivered missing from digest; output: $OUT"
fi

# ── Test 9: CHUMP_TICK_PREAMBLE=0 disables tick-preamble (exits silently) ────
echo ""
echo "=== Test 9: CHUMP_TICK_PREAMBLE=0 disables tick-preamble ==="
OUT="$(CHUMP_AMBIENT_LOG="$AMBIENT_LOG" CHUMP_TICK_PREAMBLE=0 \
    bash "$SCRIPT" --tick-preamble --role test-role 2>/dev/null || true)"

if [[ -z "$OUT" ]]; then
    _pass "empty output when CHUMP_TICK_PREAMBLE=0"
else
    _fail "expected empty output but got: $OUT"
fi

# ── Test 10: autopilot log written ───────────────────────────────────────────
echo ""
echo "=== Test 10: autopilot log written ==="
LOGTEST_DIR="$WORK_DIR/logtest"
mkdir -p "$LOGTEST_DIR/autopilot-logs"
LOGTEST_LOG="$LOGTEST_DIR/ambient.jsonl"
printf '{"ts":"2026-05-30T00:00:00Z","kind":"FEEDBACK","note":"log test event"}\n' > "$LOGTEST_LOG"

CHUMP_AMBIENT_LOG="$LOGTEST_LOG" \
    bash "$SCRIPT" --tick-preamble --role logtest 2>/dev/null || true

CURATOR_LOG="$LOGTEST_DIR/autopilot-logs/curator-logtest.log"
if [[ -f "$CURATOR_LOG" ]] && grep -q "tick-preamble" "$CURATOR_LOG"; then
    _pass "autopilot-logs/curator-logtest.log written with tick-preamble header"
else
    _fail "autopilot log missing or missing tick-preamble header at $CURATOR_LOG"
fi

# ── Test 11: ambient-context-inject.sh still parses as valid bash ────────────
echo ""
echo "=== Test 11: bash -n syntax check ==="
if bash -n "$SCRIPT" 2>/dev/null; then
    _pass "ambient-context-inject.sh passes bash -n"
else
    _fail "ambient-context-inject.sh failed bash -n syntax check"
fi

# ── Test 12: loop scripts pass bash -n after modification ─────────────────────
echo ""
echo "=== Test 12: modified loop scripts pass bash -n ==="
for loop_script in \
    "$REPO_ROOT/scripts/coord/ci-audit-loop.sh" \
    "$REPO_ROOT/scripts/coord/handoff-loop.sh" \
    "$REPO_ROOT/scripts/coord/md-links-loop.sh" \
    "$REPO_ROOT/scripts/coord/decompose-loop.sh" \
    "$REPO_ROOT/scripts/coord/opus-shepherd-triage.sh"; do
    name="$(basename "$loop_script")"
    if bash -n "$loop_script" 2>/dev/null; then
        _pass "$name passes bash -n"
    else
        _fail "$name failed bash -n syntax check"
    fi
done

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
if [[ "$FAIL" -gt 0 ]]; then
    exit 1
fi
exit 0
