#!/usr/bin/env bash
# test-transient-retrigger.sh — INFRA-1899
#
# Smoke-tests the transient-retrigger daemon's --once mode using the CI
# mock hooks (CHUMP_TRANSIENT_MOCK_PR_LIST / CHUMP_TRANSIENT_MOCK_FAILURE_FOR_<N>
# / CHUMP_TRANSIENT_MOCK_LABELS_FOR_<N> / CHUMP_TRANSIENT_DRY_RUN=1).
#
# Cases:
#   1. CHUMP_TRANSIENT_RETRIGGER_DISABLED=1 short-circuits cleanly (exit 0,
#      no ambient writes).
#   2. A PR with an audit-cancelled failure pattern triggers the retrigger
#      path: ambient gets kind=transient_auto_retriggered, state ledger
#      gets one line.
#   3. Cap (2/PR/6h) stops further retries: pre-seed the state ledger with
#      2 recent entries for the same PR, run again, assert NO new ambient
#      transient_auto_retriggered event is emitted.
#   4. Unknown failure class is skipped: a PR whose mock-log doesn't match
#      any catalog regex emits NO transient_auto_retriggered event.
#
# All cases run with CHUMP_TRANSIENT_DRY_RUN=1 so no real git push happens.

set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
DAEMON="$REPO_ROOT/scripts/coord/transient-retrigger.sh"
CATALOG="$REPO_ROOT/scripts/coord/transient-classes.json"
[ -x "$DAEMON" ] || { echo "FAIL: daemon not executable at $DAEMON" >&2; exit 1; }
[ -f "$CATALOG" ] || { echo "FAIL: catalog missing at $CATALOG" >&2; exit 1; }

SANDBOX="$(mktemp -d -t infra-1899.XXXXXX)"
trap 'rm -rf "$SANDBOX"' EXIT

pass() { printf '[PASS] %s\n' "$*"; }
fail() { printf '[FAIL] %s\n' "$*" >&2; exit 1; }

# ── case 1: disabled bypass ───────────────────────────────────────────────
AMBIENT="$SANDBOX/c1-ambient.jsonl"
STATE="$SANDBOX/c1-state.jsonl"
: > "$AMBIENT"
out=$(CHUMP_TRANSIENT_RETRIGGER_DISABLED=1 \
      CHUMP_TRANSIENT_AMBIENT_LOG="$AMBIENT" \
      CHUMP_TRANSIENT_STATE_FILE="$STATE" \
      CHUMP_TRANSIENT_CATALOG="$CATALOG" \
      bash "$DAEMON" --once 2>&1) || true
[ "$(wc -l < "$AMBIENT" | awk '{print $1}')" -eq 0 ] || fail "case 1: ambient should be untouched with DISABLED=1"
echo "$out" | grep -q "exiting cleanly" || fail "case 1: expected disabled-message on stdout; got: $out"
pass "case 1: CHUMP_TRANSIENT_RETRIGGER_DISABLED=1 short-circuits cleanly"

# ── case 2: recognized transient triggers retry ──────────────────────────
AMBIENT="$SANDBOX/c2-ambient.jsonl"
STATE="$SANDBOX/c2-state.jsonl"
: > "$AMBIENT"
: > "$STATE"
CHUMP_TRANSIENT_AMBIENT_LOG="$AMBIENT" \
CHUMP_TRANSIENT_STATE_FILE="$STATE" \
CHUMP_TRANSIENT_CATALOG="$CATALOG" \
CHUMP_TRANSIENT_DRY_RUN=1 \
CHUMP_TRANSIENT_MOCK_PR_LIST=$'9001\tchump/infra-fake-9001' \
CHUMP_TRANSIENT_MOCK_FAILURE_FOR_9001="audit conclusion=cancelled in CI step xyz" \
CHUMP_TRANSIENT_MOCK_LABELS_FOR_9001="" \
    bash "$DAEMON" --once >/dev/null 2>&1 || true
if ! grep -q '"kind":"transient_auto_retriggered"' "$AMBIENT"; then
    fail "case 2: expected transient_auto_retriggered emit; ambient=$(cat "$AMBIENT")"
fi
if ! grep -q '"failure_class":"audit_cancelled"' "$AMBIENT"; then
    fail "case 2: expected audit_cancelled classification; ambient=$(cat "$AMBIENT")"
fi
if ! grep -q '"pr":"9001"' "$STATE"; then
    fail "case 2: expected state-ledger entry for PR 9001; state=$(cat "$STATE")"
fi
pass "case 2: recognized transient (audit_cancelled) triggers retry"

# ── case 3: cap stops further retries ────────────────────────────────────
AMBIENT="$SANDBOX/c3-ambient.jsonl"
STATE="$SANDBOX/c3-state.jsonl"
: > "$AMBIENT"
NOW=$(date +%s)
printf '{"unix_ts":%d,"pr":"9002","failure_class":"audit_cancelled","attempt":1}\n' "$NOW" > "$STATE"
printf '{"unix_ts":%d,"pr":"9002","failure_class":"audit_cancelled","attempt":2}\n' "$NOW" >> "$STATE"
CHUMP_TRANSIENT_AMBIENT_LOG="$AMBIENT" \
CHUMP_TRANSIENT_STATE_FILE="$STATE" \
CHUMP_TRANSIENT_CATALOG="$CATALOG" \
CHUMP_TRANSIENT_DRY_RUN=1 \
CHUMP_TRANSIENT_MOCK_PR_LIST=$'9002\tchump/infra-fake-9002' \
CHUMP_TRANSIENT_MOCK_FAILURE_FOR_9002="audit conclusion=cancelled in CI step abc" \
CHUMP_TRANSIENT_MOCK_LABELS_FOR_9002="" \
    bash "$DAEMON" --once >/dev/null 2>&1 || true
if grep -q '"kind":"transient_auto_retriggered"' "$AMBIENT"; then
    fail "case 3: cap should have suppressed retry; ambient=$(cat "$AMBIENT")"
fi
# State ledger should be untouched (still 2 entries).
state_lines=$(wc -l < "$STATE" | awk '{print $1}')
[ "$state_lines" -eq 2 ] || fail "case 3: state ledger should still have 2 entries; got $state_lines"
pass "case 3: cap (2/PR/6h) stops further retries"

# ── case 4: unknown failure class skipped ────────────────────────────────
AMBIENT="$SANDBOX/c4-ambient.jsonl"
STATE="$SANDBOX/c4-state.jsonl"
: > "$AMBIENT"
: > "$STATE"
CHUMP_TRANSIENT_AMBIENT_LOG="$AMBIENT" \
CHUMP_TRANSIENT_STATE_FILE="$STATE" \
CHUMP_TRANSIENT_CATALOG="$CATALOG" \
CHUMP_TRANSIENT_DRY_RUN=1 \
CHUMP_TRANSIENT_MOCK_PR_LIST=$'9003\tchump/infra-fake-9003' \
CHUMP_TRANSIENT_MOCK_FAILURE_FOR_9003="error[E0382]: borrow of moved value at src/foo.rs:42 — genuine compile error, not transient" \
CHUMP_TRANSIENT_MOCK_LABELS_FOR_9003="" \
    bash "$DAEMON" --once >/dev/null 2>&1 || true
if grep -q '"kind":"transient_auto_retriggered"' "$AMBIENT"; then
    fail "case 4: unknown failure class should not trigger retry; ambient=$(cat "$AMBIENT")"
fi
if [ -s "$STATE" ]; then
    fail "case 4: state ledger should be empty for unknown failure; state=$(cat "$STATE")"
fi
pass "case 4: unknown failure class skipped (no retrigger)"

echo "All INFRA-1899 transient-retrigger tests passed."
