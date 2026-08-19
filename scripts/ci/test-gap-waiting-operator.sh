#!/usr/bin/env bash
# test-gap-waiting-operator.sh — EFFECTIVE-038
#
# Verifies the A2A L2 task state machine: gaps can suspend into
# `waiting_operator` carrying a structured JSON question payload
# (input_required | auth_required) instead of either guessing wrong or
# spawning a free-text follow-up gap — and RESUME exactly where they paused
# via `chump gap respond`. Also verifies the SLA sweep auto-fails a stalled
# suspension instead of hanging it forever (A2A's own spec has no timeout).
#
# AC:
#   1. `chump gap suspend <ID> --kind input_required --question JSON` flips
#      status to waiting_operator and stores the JSON payload.
#   2. `chump gap respond <ID> --answer JSON` resumes the gap back to its
#      pre-suspend status and folds the answer into the payload.
#   3. `chump gap suspend <ID> --kind auth_required ...` works identically —
#      ties RESILIENT-054 (missing credential must suspend, not silently die).
#   4. `chump gap sla-check` auto-fails a waiting_operator gap whose SLA has
#      elapsed and emits kind=task_stalled.
#   5. Invalid --kind is rejected.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

pass() { printf '[PASS] %s\n' "$*"; }
fail() { printf '[FAIL] %s\n' "$*" >&2; exit 1; }

CHUMP_BIN="${CHUMP_BIN:-chump}"
command -v "$CHUMP_BIN" >/dev/null 2>&1 || fail "Cannot find chump binary"

cd "$REPO_ROOT" || fail "Cannot cd to $REPO_ROOT"
export CHUMP_REPO="$REPO_ROOT"

status_of() {
  $CHUMP_BIN gap show "$1" | grep '^  status: ' | awk '{print $2}' || echo "error"
}

# ── Test 1+2: input_required suspend → respond resumes ─────────────────────
TEST_GAP=$($CHUMP_BIN gap reserve --domain EFFECTIVE --title "EFFECTIVE: waiting-operator smoke (input_required)" --priority P3 --force 2>&1 | grep '^EFFECTIVE-' | tail -1)
[ -n "$TEST_GAP" ] || fail "Cannot reserve test gap"

status_before=$(status_of "$TEST_GAP")
[ "$status_before" = "open" ] || fail "Gap not open before suspend: $status_before"

$CHUMP_BIN gap suspend "$TEST_GAP" --kind input_required \
  --question '{"message":"pick a migration strategy","options":["A","B"]}' \
  || fail "gap suspend (input_required) failed"

status_suspended=$(status_of "$TEST_GAP")
[ "$status_suspended" = "waiting_operator" ] || fail "Status not waiting_operator after suspend: $status_suspended"
pass "gap suspend --kind input_required flips status to waiting_operator ($TEST_GAP)"

if [ -f "$REPO_ROOT/.chump-locks/ambient.jsonl" ]; then
  tail -50 "$REPO_ROOT/.chump-locks/ambient.jsonl" | grep -q "\"kind\":\"gap_waiting_operator\".*\"gap_id\":\"$TEST_GAP\".*\"suspend_kind\":\"input_required\"" \
    || fail "gap_waiting_operator ambient event missing/malformed for $TEST_GAP"
  pass "gap_waiting_operator ambient event emitted for $TEST_GAP"
fi

# Suspending an already-suspended gap must fail (no double-suspend clobber).
if $CHUMP_BIN gap suspend "$TEST_GAP" --kind input_required --question '{}' 2>/dev/null; then
  fail "gap suspend accepted a gap that was already waiting_operator"
fi
pass "gap suspend rejects a gap already waiting_operator"

$CHUMP_BIN gap respond "$TEST_GAP" --answer '{"choice":"A"}' \
  || fail "gap respond failed"

status_after=$(status_of "$TEST_GAP")
[ "$status_after" = "open" ] || fail "Status not restored to open after respond: $status_after"
pass "gap respond resumes gap back to pre-suspend status ($TEST_GAP)"

if [ -f "$REPO_ROOT/.chump-locks/ambient.jsonl" ]; then
  tail -50 "$REPO_ROOT/.chump-locks/ambient.jsonl" | grep -q "\"kind\":\"gap_responded\".*\"gap_id\":\"$TEST_GAP\"" \
    || fail "gap_responded ambient event missing/malformed for $TEST_GAP"
  pass "gap_responded ambient event emitted for $TEST_GAP"
fi

# Responding again (no longer waiting_operator) must fail.
if $CHUMP_BIN gap respond "$TEST_GAP" --answer '{}' 2>/dev/null; then
  fail "gap respond accepted a gap that was not waiting_operator"
fi
pass "gap respond rejects a gap that is not waiting_operator"

# ── Test 3: auth_required suspend (RESILIENT-054 tie-in) ───────────────────
AUTH_GAP=$($CHUMP_BIN gap reserve --domain EFFECTIVE --title "EFFECTIVE: waiting-operator smoke (auth_required)" --priority P3 --force 2>&1 | grep '^EFFECTIVE-' | tail -1)
[ -n "$AUTH_GAP" ] || fail "Cannot reserve auth_required test gap"

$CHUMP_BIN gap suspend "$AUTH_GAP" --kind auth_required \
  --question '{"message":"credential exhausted"}' --max-wait-seconds 3600 \
  || fail "gap suspend (auth_required) failed"

status_auth=$(status_of "$AUTH_GAP")
[ "$status_auth" = "waiting_operator" ] || fail "Status not waiting_operator after auth_required suspend: $status_auth"
pass "gap suspend --kind auth_required suspends instead of silently dying ($AUTH_GAP)"

$CHUMP_BIN gap respond "$AUTH_GAP" --answer '{"rotated":true}' \
  || fail "gap respond (auth_required) failed"
pass "gap respond resumes an auth_required suspension ($AUTH_GAP)"

# ── Test 4: SLA sweep auto-fails a stalled suspension ───────────────────────
SLA_GAP=$($CHUMP_BIN gap reserve --domain EFFECTIVE --title "EFFECTIVE: waiting-operator SLA smoke" --priority P3 --force 2>&1 | grep '^EFFECTIVE-' | tail -1)
[ -n "$SLA_GAP" ] || fail "Cannot reserve SLA test gap"

$CHUMP_BIN gap suspend "$SLA_GAP" --kind input_required \
  --question '{"message":"never answered"}' --max-wait-seconds 0 \
  || fail "gap suspend (SLA) failed"

$CHUMP_BIN gap sla-check || fail "gap sla-check failed"

status_sla=$(status_of "$SLA_GAP")
[ "$status_sla" = "failed" ] || fail "Status not failed after SLA elapse: $status_sla"
pass "gap sla-check auto-fails a stalled waiting_operator gap ($SLA_GAP)"

if [ -f "$REPO_ROOT/.chump-locks/ambient.jsonl" ]; then
  tail -50 "$REPO_ROOT/.chump-locks/ambient.jsonl" | grep -q "\"kind\":\"task_stalled\".*\"gap_id\":\"$SLA_GAP\"" \
    || fail "task_stalled ambient event missing/malformed for $SLA_GAP"
  pass "task_stalled ambient event emitted for $SLA_GAP"
fi

# ── Test 5: invalid --kind is rejected ──────────────────────────────────────
BAD_GAP=$($CHUMP_BIN gap reserve --domain EFFECTIVE --title "EFFECTIVE: waiting-operator invalid-kind smoke" --priority P3 --force 2>&1 | grep '^EFFECTIVE-' | tail -1)
[ -n "$BAD_GAP" ] || fail "Cannot reserve invalid-kind test gap"
if $CHUMP_BIN gap suspend "$BAD_GAP" --kind bogus --question '{}' 2>/dev/null; then
  fail "gap suspend accepted an invalid --kind"
fi
status_bad=$(status_of "$BAD_GAP")
[ "$status_bad" = "open" ] || fail "Gap status changed despite invalid --kind: $status_bad"
pass "gap suspend rejects invalid --kind and leaves status unchanged"

pass "All EFFECTIVE-038 waiting-operator tests passed"
