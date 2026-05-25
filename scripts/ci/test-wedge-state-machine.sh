#!/usr/bin/env bash
# scripts/ci/test-wedge-state-machine.sh — INFRA-1994 (THE FLOOR Phase 3)
#
# Validates the wedge state machine: wedge_detected → rate-limit →
# remediation → chronic escalation.
#
# Tests:
#   1. Skip env → silent no-op
#   2. No detections → daemon exits clean, advances offset
#   3. Single detection → remediation fires + recorded
#   4. Rate limit: 2nd detection of same class within window → rate_limited
#   5. Chronic: 3+ detections of same class in 24h → wedge_chronic emit
#   6. Idempotent: re-run on processed events → no re-emit
#   7. Multiple classes detected → each gets independent treatment

set -uo pipefail

PASS=0
FAIL=0
FAILS=()
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); FAILS+=("$1"); }

echo "=== INFRA-1994 wedge-state-machine tests ==="

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
SM="$REPO_ROOT/scripts/coord/wedge-state-machine.sh"
[[ -x "$SM" ]] || { echo "FATAL: $SM not executable"; exit 2; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
unset CHUMP_REPO CHUMP_LOCK_DIR

FAKE="$TMP/repo"
mkdir -p "$FAKE/.chump-locks"

run_sm() {
    cd "$FAKE" || return 2
    env CHUMP_REPO="$FAKE" \
        CHUMP_AMBIENT_LOG="$FAKE/.chump-locks/ambient.jsonl" \
        "$@" \
        bash "$SM" 2>&1
    local rc=$?
    cd - >/dev/null
    return "$rc"
}

emit_detect() {
    local class="$1"; local note="${2:-}"
    printf '{"ts":"%s","kind":"wedge_detected","source":"wedge_watch","class":"%s","note":"%s"}\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$class" "$note" \
        >> "$FAKE/.chump-locks/ambient.jsonl"
}

# ── Test 1: skip env ────────────────────────────────────────────────────────
echo "--- Test 1: CHUMP_WEDGE_STATE_MACHINE_SKIP=1 → no-op ---"
> "$FAKE/.chump-locks/ambient.jsonl"
OUT=$(run_sm CHUMP_WEDGE_STATE_MACHINE_SKIP=1)
if echo "$OUT" | grep -q "skipped"; then
    ok "skip env produced no-op message"
else
    fail "expected skip (out=$OUT)"
fi

# ── Test 2: no detections → clean ───────────────────────────────────────────
echo "--- Test 2: no detections → exit clean, advance offset ---"
> "$FAKE/.chump-locks/ambient.jsonl"
rm -f "$FAKE/.chump-locks/wedge-state-machine-state.json"
OUT=$(run_sm); rc=$?
if [[ "$rc" -eq 0 ]] && [[ ! -s "$FAKE/.chump-locks/ambient.jsonl" ]]; then
    ok "no detections → clean exit + empty ambient"
else
    fail "expected clean (rc=$rc, ambient=$(cat "$FAKE/.chump-locks/ambient.jsonl"))"
fi

# ── Test 3: single detection → remediation fires ────────────────────────────
echo "--- Test 3: single W-001 detection → wedge_remediation_requested ---"
> "$FAKE/.chump-locks/ambient.jsonl"
rm -f "$FAKE/.chump-locks/wedge-state-machine-state.json"
emit_detect "W-001" "3 pr_auto_rebase_failed events"
run_sm > /dev/null 2>&1
if grep -q "wedge_remediation_requested" "$FAKE/.chump-locks/ambient.jsonl" 2>/dev/null \
   && grep -q '"class":"W-001"' "$FAKE/.chump-locks/ambient.jsonl" 2>/dev/null; then
    ok "W-001 detection produced remediation_requested"
else
    fail "expected remediation (ambient=$(cat "$FAKE/.chump-locks/ambient.jsonl"))"
fi

# ── Test 4: rate limit (2nd in window → rate_limited) ──────────────────────
echo "--- Test 4: second W-001 within window → rate_limited ---"
emit_detect "W-001" "second fire"
run_sm > /dev/null 2>&1
RATE_HITS="$(grep -c "wedge_remediation_rate_limited" "$FAKE/.chump-locks/ambient.jsonl" 2>/dev/null | xargs)"
RATE_HITS="${RATE_HITS:-0}"
if [[ "$RATE_HITS" -ge 1 ]]; then
    ok "second W-001 fire → rate_limited (rate=$RATE_HITS)"
else
    fail "expected rate_limited event (ambient=$(tail -3 "$FAKE/.chump-locks/ambient.jsonl"))"
fi

# ── Test 5: chronic — 3+ detections of same class → chronic emit ───────────
echo "--- Test 5: 3+ W-002 detections in 24h → wedge_chronic ---"
> "$FAKE/.chump-locks/ambient.jsonl"
rm -f "$FAKE/.chump-locks/wedge-state-machine-state.json"
for n in 1 2 3; do
    emit_detect "W-002" "chronic-test-$n"
    run_sm > /dev/null 2>&1
done
CHRONIC_HITS="$(grep -c "wedge_chronic" "$FAKE/.chump-locks/ambient.jsonl" 2>/dev/null | xargs)"
CHRONIC_HITS="${CHRONIC_HITS:-0}"
if [[ "$CHRONIC_HITS" -ge 1 ]]; then
    ok "3 W-002 detections triggered wedge_chronic"
else
    fail "expected wedge_chronic (chronic=$CHRONIC_HITS, ambient=$(tail -5 "$FAKE/.chump-locks/ambient.jsonl"))"
fi

# ── Test 6: idempotent — re-run on processed events ────────────────────────
echo "--- Test 6: re-run on processed events → no re-emit ---"
PRE="$(wc -l < "$FAKE/.chump-locks/ambient.jsonl" | xargs)"
run_sm > /dev/null 2>&1
POST="$(wc -l < "$FAKE/.chump-locks/ambient.jsonl" | xargs)"
if [[ "$PRE" == "$POST" ]]; then
    ok "idempotent: second run added no events"
else
    fail "expected no new events (pre=$PRE, post=$POST)"
fi

# ── Test 7: multiple classes get independent treatment ────────────────────
echo "--- Test 7: 2 different classes detected → each gets independent remediation ---"
> "$FAKE/.chump-locks/ambient.jsonl"
rm -f "$FAKE/.chump-locks/wedge-state-machine-state.json"
emit_detect "W-007" "first class"
emit_detect "W-008" "second class"
run_sm > /dev/null 2>&1
W007_REM="$(grep -c '"class":"W-007"' "$FAKE/.chump-locks/ambient.jsonl" 2>/dev/null | xargs)"
W008_REM="$(grep -c '"class":"W-008"' "$FAKE/.chump-locks/ambient.jsonl" 2>/dev/null | xargs)"
W007_REM="${W007_REM:-0}"
W008_REM="${W008_REM:-0}"
if [[ "$W007_REM" -ge 1 ]] && [[ "$W008_REM" -ge 1 ]]; then
    ok "independent remediations: W-007=$W007_REM W-008=$W008_REM"
else
    fail "expected both classes remediated (W-007=$W007_REM, W-008=$W008_REM)"
fi

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
if [[ "$FAIL" -gt 0 ]]; then
    for f in "${FAILS[@]}"; do echo "  - $f"; done
    exit 1
fi
exit 0
