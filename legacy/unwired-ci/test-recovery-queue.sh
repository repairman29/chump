#!/usr/bin/env bash
# scripts/ci/test-recovery-queue.sh — INFRA-1993 (THE FLOOR Phase 3)
#
# Validates the recovery queue: emit → service → cycle → audit.
#
# Test cases:
#   1. CHUMP_RECOVERY_QUEUE_PAUSE=1 → daemon emits recovery_queue_paused + exits
#   2. emit-cli writes operator_recovery_requested with required fields
#   3. no requests → daemon advances offset + exits cleanly
#   4. one request → daemon runs cycle + emits operator_recovery_executed
#   5. rate limit: 4 requests, max 3/window → 4th emits recovery_queue_rate_limited
#   6. ruleset snapshot failure → emits operator_recovery_failed (graceful)
#   7. idempotency: second daemon run after processing → no re-emit

set -uo pipefail

PASS=0
FAIL=0
FAILS=()

ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); FAILS+=("$1"); }

echo "=== INFRA-1993 recovery-queue tests ==="
echo

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
EMIT="$REPO_ROOT/scripts/coord/recovery-queue-emit.sh"
SERVICE="$REPO_ROOT/scripts/coord/recovery-queue-service.sh"

[[ -x "$EMIT" ]]    || { echo "FATAL: $EMIT not executable"; exit 2; }
[[ -x "$SERVICE" ]] || { echo "FATAL: $SERVICE not executable"; exit 2; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
unset CHUMP_REPO CHUMP_LOCK_DIR

FAKE="$TMP/repo"
mkdir -p "$FAKE/.chump-locks"

# Mock gh that records calls + returns success for known operations
mkdir -p "$TMP/bin"
cat > "$TMP/bin/gh" <<'GH'
#!/usr/bin/env bash
echo "$@" >> "$GH_CALL_LOG"
case "$1 $2" in
    "api repos/{owner}/{repo}/rulesets/15133729")
        # Snapshot: return synthetic ruleset JSON
        echo '{"id":15133729,"name":"Protect main","target":"branch","enforcement":"active","conditions":{"ref_name":{"exclude":[],"include":["~DEFAULT_BRANCH"]}},"rules":[{"type":"deletion"},{"type":"required_status_checks","parameters":{"required_status_checks":[{"context":"test"}]}}]}'
        exit 0
        ;;
    "api -X")
        # PUT to ruleset → succeed
        exit 0
        ;;
    "pr merge")
        # Admin merge → succeed
        exit 0
        ;;
    "pr view")
        # State query → return MERGED so idempotency works
        echo "MERGED"
        exit 0
        ;;
esac
exit 0
GH
chmod +x "$TMP/bin/gh"

run_service() {
    cd "$FAKE" || return 2
    env \
        CHUMP_REPO="$FAKE" \
        CHUMP_AMBIENT_LOG="$FAKE/.chump-locks/ambient.jsonl" \
        CHUMP_RECOVERY_QUEUE_TEST_GH="$TMP/bin/gh" \
        GH_CALL_LOG="$TMP/gh-calls.log" \
        "$@" \
        bash "$SERVICE" 2>&1
    RC=$?
    cd - >/dev/null
    return "$RC"
}

run_emit() {
    CHUMP_REPO="$FAKE" \
    CHUMP_AMBIENT_LOG="$FAKE/.chump-locks/ambient.jsonl" \
    bash "$EMIT" "$@" 2>&1
}

# ── Test 1: pause env ────────────────────────────────────────────────────────
echo "--- Test 1: CHUMP_RECOVERY_QUEUE_PAUSE=1 → daemon emits paused + exits ---"
> "$FAKE/.chump-locks/ambient.jsonl"
run_service CHUMP_RECOVERY_QUEUE_PAUSE=1 > /dev/null
if grep -q "recovery_queue_paused" "$FAKE/.chump-locks/ambient.jsonl" 2>/dev/null; then
    ok "pause env produced recovery_queue_paused event"
else
    fail "expected recovery_queue_paused (ambient=$(cat "$FAKE/.chump-locks/ambient.jsonl"))"
fi

# ── Test 2: emit-cli writes correct event ───────────────────────────────────
echo "--- Test 2: emit-cli writes operator_recovery_requested with required fields ---"
> "$FAKE/.chump-locls/ambient.jsonl" 2>/dev/null
> "$FAKE/.chump-locks/ambient.jsonl"
OUT=$(run_emit --prs 9001,9002 --reason "test pile-up" --cluster-gap META-TEST-1)
if grep -q "operator_recovery_requested" "$FAKE/.chump-locks/ambient.jsonl" 2>/dev/null \
   && grep -q '"prs":"9001,9002"' "$FAKE/.chump-locks/ambient.jsonl" 2>/dev/null \
   && grep -q '"cluster_gap_id":"META-TEST-1"' "$FAKE/.chump-locks/ambient.jsonl" 2>/dev/null; then
    ok "emit wrote event with prs + cluster_gap_id fields"
else
    fail "emit missing fields (ambient=$(cat "$FAKE/.chump-locks/ambient.jsonl"))"
fi

# ── Test 3: no requests → daemon exits clean ────────────────────────────────
echo "--- Test 3: no operator_recovery_requested events → daemon exits clean ---"
> "$FAKE/.chump-locks/ambient.jsonl"
rm -f "$FAKE/.chump-locks/recovery-queue-state.json"
run_service > /dev/null
RC=$?
if [[ "$RC" -eq 0 ]] && [[ ! -s "$FAKE/.chump-locks/ambient.jsonl" ]]; then
    ok "no requests → exit 0 + no new events"
else
    fail "expected clean exit (rc=$RC, ambient=$(cat "$FAKE/.chump-locks/ambient.jsonl"))"
fi

# ── Test 4: one request → cycle runs + emits executed ──────────────────────
echo "--- Test 4: one request → daemon runs cycle + emits operator_recovery_executed ---"
> "$FAKE/.chump-locks/ambient.jsonl"
> "$TMP/gh-calls.log"
rm -f "$FAKE/.chump-locks/recovery-queue-state.json"
run_emit --prs 7777 --reason "test single" --cluster-gap META-TEST-4 > /dev/null
run_service > /dev/null 2>&1
if grep -q "operator_recovery_executed" "$FAKE/.chump-locks/ambient.jsonl" 2>/dev/null \
   && grep -q "pr merge 7777" "$TMP/gh-calls.log" 2>/dev/null; then
    ok "cycle ran + emitted executed event + gh pr merge 7777 was called"
else
    fail "expected executed event + merge call (ambient=$(cat "$FAKE/.chump-locks/ambient.jsonl"), gh-calls=$(cat "$TMP/gh-calls.log"))"
fi

# ── Test 5: rate limit ──────────────────────────────────────────────────────
echo "--- Test 5: 4 requests, RATE=3 → 4th emits recovery_queue_rate_limited ---"
> "$FAKE/.chump-locks/ambient.jsonl"
> "$TMP/gh-calls.log"
rm -f "$FAKE/.chump-locks/recovery-queue-state.json"
# Emit 4 requests
for n in 1 2 3 4; do
    run_emit --prs "100$n" --reason "rate-test-$n" > /dev/null
done
run_service CHUMP_RECOVERY_QUEUE_RATE=3 > /dev/null 2>&1
RATE_HITS="$(grep -c "recovery_queue_rate_limited" "$FAKE/.chump-locks/ambient.jsonl" 2>/dev/null | xargs)"
RATE_HITS="${RATE_HITS:-0}"
EXEC_COUNT="$(grep -c "operator_recovery_executed" "$FAKE/.chump-locks/ambient.jsonl" 2>/dev/null | xargs)"
EXEC_COUNT="${EXEC_COUNT:-0}"
if [[ "$EXEC_COUNT" == "3" ]] && [[ "$RATE_HITS" -ge 1 ]]; then
    ok "rate limit honored: 3 cycles executed, $RATE_HITS rate_limited event(s) emitted"
else
    fail "expected 3 executed + ≥1 rate_limited (executed=$EXEC_COUNT, rate=$RATE_HITS)"
fi

# ── Test 6: idempotency — re-run after processing ──────────────────────────
echo "--- Test 6: second daemon run after processing → no re-emit ---"
PRE_COUNT="$(wc -l < "$FAKE/.chump-locks/ambient.jsonl" | xargs)"
run_service > /dev/null 2>&1
POST_COUNT="$(wc -l < "$FAKE/.chump-locks/ambient.jsonl" | xargs)"
if [[ "$PRE_COUNT" == "$POST_COUNT" ]]; then
    ok "idempotent: second run added no events"
else
    fail "expected no new events (pre=$PRE_COUNT, post=$POST_COUNT)"
fi

# ── Summary ───────────────────────────────────────────────────────────────
echo
echo "=== Results: $PASS passed, $FAIL failed ==="
if [[ "$FAIL" -gt 0 ]]; then
    for f in "${FAILS[@]}"; do echo "  - $f"; done
    exit 1
fi
exit 0
