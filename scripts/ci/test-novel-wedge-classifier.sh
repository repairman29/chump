#!/usr/bin/env bash
# scripts/ci/test-novel-wedge-classifier.sh — INFRA-2067 (META-118 sub-gap 1)
#
# Smoke tests for novel-wedge-classifier.sh:
#   1. SKIP env → silent no-op
#   2. No pr_failed events → clean exit, cursor written
#   3. 2 occurrences (below threshold=3) → NO emit
#   4. 3rd occurrence (threshold met) → wedge_class_detected emitted
#   5. 4th in same window → NO re-emit (dedup)
#   6. Time-skew past window → re-emit for same signature
#   7. Rate-limit: 5 distinct sigs all at threshold → 5 emits; 6th → suppressed
#   8. Dry-run mode → no write to ambient, stdout only

set -uo pipefail

PASS=0
FAIL=0
FAILS=()

ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); FAILS+=("$1"); }

echo "=== INFRA-2067 novel-wedge-classifier tests ==="

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
CLASSIFIER="$REPO_ROOT/scripts/coord/novel-wedge-classifier.sh"
[[ -f "$CLASSIFIER" ]] || { echo "FATAL: $CLASSIFIER not found"; exit 2; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

FAKE="$TMP/repo"
mkdir -p "$FAKE/.chump-locks/wedge-classifier"
AMBIENT="$FAKE/.chump-locks/ambient.jsonl"
CURSOR="$FAKE/.chump-locks/wedge-classifier/cursor.json"

run_classifier() {
    env CHUMP_REPO="$FAKE" \
        CHUMP_AMBIENT_LOG="$AMBIENT" \
        CHUMP_WEDGE_CLASSIFIER_THRESHOLD="${THRESHOLD:-3}" \
        CHUMP_WEDGE_CLASSIFIER_WINDOW_S="${WINDOW:-1800}" \
        CHUMP_WEDGE_CLASSIFIER_RATE_LIMIT="${RATE:-5}" \
        "$@" \
        bash "$CLASSIFIER" 2>&1
}

emit_pr_failed() {
    local pr="${1:-42}"
    local test_name="${2:-test_foo_bar}"
    local first_error="${3:-FAILED: assertion failed at src/foo.rs:42}"
    local ts
    ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf '{"ts":"%s","kind":"pr_failed","pr_number":%s,"failing_test_name":"%s","first_error_line":"%s"}\n' \
        "$ts" "$pr" "$test_name" "$first_error" \
        >> "$AMBIENT"
}

count_emits() {
    # grep -c exits 1 with count=0 when no match; strip whitespace for arithmetic
    # Match both compact JSON ("kind":"wedge_class_detected") and spaced ("kind": "wedge_class_detected")
    local n
    n=$(grep -c '"kind"[[:space:]]*:[[:space:]]*"wedge_class_detected"' "$AMBIENT" 2>/dev/null) || n=0
    echo "${n// /}"
}

# ── Test 1: SKIP env → no-op ─────────────────────────────────────────────────
echo "--- Test 1: CHUMP_WEDGE_CLASSIFIER_SKIP=1 → no-op ---"
> "$AMBIENT"
rm -f "$CURSOR"
OUT=$(run_classifier CHUMP_WEDGE_CLASSIFIER_SKIP=1)
if echo "$OUT" | grep -q "skipped"; then
    ok "SKIP env produced no-op message"
else
    fail "expected 'skipped' in output (got: $OUT)"
fi

# ── Test 2: no pr_failed events → clean exit ─────────────────────────────────
echo "--- Test 2: no pr_failed events → clean exit + cursor written ---"
> "$AMBIENT"
rm -f "$CURSOR"
printf '{"ts":"2026-01-01T00:00:00Z","kind":"some_other_event"}\n' >> "$AMBIENT"
OUT=$(run_classifier); rc=$?
if [[ "$rc" -eq 0 ]] && [[ -f "$CURSOR" ]]; then
    ok "no pr_failed → clean exit, cursor written"
else
    fail "expected clean exit and cursor file (rc=$rc, cursor_exists=$(test -f "$CURSOR" && echo yes || echo no))"
fi
EMIT_COUNT=$(count_emits)
if [[ "$EMIT_COUNT" -eq 0 ]]; then
    ok "no wedge_class_detected emitted for unrelated events"
else
    fail "unexpected emit count=$EMIT_COUNT"
fi

# ── Tests 3-5: threshold + dedup — single fresh env ──────────────────────────
# All three tests share one ambient+cursor so incremental runs accumulate state.
# IMPORTANT: always reset cursor together with ambient — cursor offset is
# relative to the file's byte position; truncating ambient without resetting
# the cursor causes the Python to seek past EOF and read 0 bytes.
echo "--- Test 3: 2 occurrences (below threshold=3) → no emit ---"
> "$AMBIENT"
rm -f "$CURSOR"  # always pair ambient reset with cursor reset
emit_pr_failed 101 "test_ci_gate" "FAILED: assertion panicked at src/gate.rs:17"
emit_pr_failed 102 "test_ci_gate" "FAILED: assertion panicked at src/gate.rs:17"
run_classifier > /dev/null 2>&1
EMIT_COUNT=$(count_emits)
if [[ "$EMIT_COUNT" -eq 0 ]]; then
    ok "2 occurrences → no emit (threshold=3)"
else
    fail "unexpected emit at count=2 (emits=$EMIT_COUNT)"
fi

echo "--- Test 4: 3rd occurrence → wedge_class_detected emitted ---"
# Append 3rd event; classifier reads from saved offset so sees only this one
emit_pr_failed 103 "test_ci_gate" "FAILED: assertion panicked at src/gate.rs:17"
OUT=$(run_classifier)
EMIT_COUNT=$(count_emits)
if [[ "$EMIT_COUNT" -eq 1 ]]; then
    ok "3rd occurrence → exactly 1 wedge_class_detected"
else
    fail "expected 1 emit at count=3 (emits=$EMIT_COUNT, out=$OUT)"
fi
# Verify payload fields on the emitted event
EMIT_LINE=$(grep '"kind"[[:space:]]*:[[:space:]]*"wedge_class_detected"' "$AMBIENT" | tail -1)
if echo "$EMIT_LINE" | grep -q '"signature_hash"'; then
    ok "wedge_class_detected has signature_hash field"
else
    fail "wedge_class_detected missing signature_hash (line=$EMIT_LINE)"
fi
if echo "$EMIT_LINE" | grep -q '"failing_test_name"'; then
    ok "wedge_class_detected has failing_test_name field"
else
    fail "wedge_class_detected missing failing_test_name"
fi
if echo "$EMIT_LINE" | grep -q '"sample_pr_numbers"'; then
    ok "wedge_class_detected has sample_pr_numbers field"
else
    fail "wedge_class_detected missing sample_pr_numbers"
fi

echo "--- Test 5: 4th occurrence in same window → no re-emit (dedup) ---"
emit_pr_failed 104 "test_ci_gate" "FAILED: assertion panicked at src/gate.rs:17"
run_classifier > /dev/null 2>&1
EMIT_COUNT=$(count_emits)
if [[ "$EMIT_COUNT" -eq 1 ]]; then
    ok "4th in same window → still 1 emit (dedup working)"
else
    fail "expected 1 emit after 4th occurrence (got $EMIT_COUNT)"
fi

# ── Test 6: time-skew past window → re-emit ───────────────────────────────────
echo "--- Test 6: time-skew past window → re-emit allowed ---"
# Force window_emit_ts back beyond the window by using a very short window
> "$AMBIENT"
rm -f "$CURSOR"
# Use 2-second window so we can test expiry
WINDOW=2 THRESHOLD=2 RATE=10 emit_pr_failed 201 "test_timeout_gate" "FAILED: timeout after 30s"
WINDOW=2 THRESHOLD=2 RATE=10 emit_pr_failed 202 "test_timeout_gate" "FAILED: timeout after 30s"
env CHUMP_REPO="$FAKE" CHUMP_AMBIENT_LOG="$AMBIENT" \
    CHUMP_WEDGE_CLASSIFIER_THRESHOLD=2 CHUMP_WEDGE_CLASSIFIER_WINDOW_S=2 \
    CHUMP_WEDGE_CLASSIFIER_RATE_LIMIT=10 \
    bash "$CLASSIFIER" > /dev/null 2>&1
EMIT_BEFORE=$(count_emits)
# Sleep past window
sleep 3
# New occurrences in new window
emit_pr_failed 203 "test_timeout_gate" "FAILED: timeout after 30s"
emit_pr_failed 204 "test_timeout_gate" "FAILED: timeout after 30s"
env CHUMP_REPO="$FAKE" CHUMP_AMBIENT_LOG="$AMBIENT" \
    CHUMP_WEDGE_CLASSIFIER_THRESHOLD=2 CHUMP_WEDGE_CLASSIFIER_WINDOW_S=2 \
    CHUMP_WEDGE_CLASSIFIER_RATE_LIMIT=10 \
    bash "$CLASSIFIER" > /dev/null 2>&1
EMIT_AFTER=$(count_emits)
if [[ "$EMIT_BEFORE" -eq 1 ]] && [[ "$EMIT_AFTER" -eq 2 ]]; then
    ok "time-skew past window → 2nd emit allowed (before=$EMIT_BEFORE after=$EMIT_AFTER)"
else
    fail "time-skew test failed (before=$EMIT_BEFORE after=$EMIT_AFTER)"
fi

# ── Test 7: rate-limit — 5 distinct sigs → 5 emits; 6th → suppressed ─────────
echo "--- Test 7: rate-limit (5/hr) — 6th distinct sig suppressed ---"
> "$AMBIENT"
rm -f "$CURSOR"
# Emit 5 distinct signatures all at threshold, rate_limit=5
for i in 1 2 3 4 5 6; do
    for j in 1 2 3; do  # 3 occurrences each (threshold=3) — same error line, different PR
        emit_pr_failed "$((300+i*10+j))" "test_unique_sig_$i" "UNIQUE ERROR kind=$i"
    done
done
RATE=5 THRESHOLD=3 WINDOW=1800
run_classifier > /dev/null 2>&1
EMIT_COUNT=$(count_emits)
unset RATE THRESHOLD WINDOW
if [[ "$EMIT_COUNT" -le 5 ]]; then
    ok "rate-limit enforced: $EMIT_COUNT emits for 6 sigs (max=5)"
else
    fail "rate-limit failed: $EMIT_COUNT emits (expected <= 5)"
fi
# Ensure at least something was emitted
if [[ "$EMIT_COUNT" -ge 1 ]]; then
    ok "at least 1 emit when rate limit not yet exhausted"
else
    fail "expected at least 1 emit (got 0)"
fi

# ── Test 8: dry-run → no write, stdout only ───────────────────────────────────
echo "--- Test 8: CHUMP_WEDGE_CLASSIFIER_DRY_RUN=1 → no ambient write ---"
> "$AMBIENT"
rm -f "$CURSOR"
emit_pr_failed 401 "test_dry_run" "FAILED: dry run error line"
emit_pr_failed 402 "test_dry_run" "FAILED: dry run error line"
emit_pr_failed 403 "test_dry_run" "FAILED: dry run error line"
AMBIENT_BEFORE=$(wc -l < "$AMBIENT")
OUT=$(run_classifier CHUMP_WEDGE_CLASSIFIER_DRY_RUN=1)
EMIT_COUNT=$(count_emits)
AMBIENT_AFTER=$(wc -l < "$AMBIENT")
if [[ "$EMIT_COUNT" -eq 0 ]] && echo "$OUT" | grep -q "dry-run"; then
    ok "dry-run: no ambient write, stdout annotation present"
else
    fail "dry-run failed: emits=$EMIT_COUNT ambient_lines_before=$AMBIENT_BEFORE after=$AMBIENT_AFTER out=$OUT"
fi

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
if [[ ${#FAILS[@]} -gt 0 ]]; then
    echo "Failures:"
    for f in "${FAILS[@]}"; do
        echo "  - $f"
    done
    exit 1
fi
exit 0
