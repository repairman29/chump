#!/usr/bin/env bash
# INFRA-2158 (META-125/C7) smoke test: chump consensus resolve/status.
# Seeds vote events in a tmp ambient.jsonl, runs `chump consensus resolve`,
# asserts a kind=consensus_result event is emitted + idempotent re-resolve
# is a no-op, then runs `chump consensus status` and asserts it reports
# the durable decision state.
set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
CHUMP_BIN="${CHUMP_BIN:-$REPO_ROOT/target/debug/chump}"

if [[ ! -x "$CHUMP_BIN" ]]; then
    echo "[test-chump-consensus] building chump binary..."
    cargo build --manifest-path "$REPO_ROOT/Cargo.toml" --bin chump --quiet
fi

TMPDIR_TEST="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_TEST"' EXIT

AMBIENT="$TMPDIR_TEST/ambient.jsonl"
export CHUMP_AMBIENT_LOG="$AMBIENT"
export CHUMP_REPO_ROOT="$REPO_ROOT"

CORR_ID="test-consensus-$$"
TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

assert_contains() {
    local needle="$1" haystack="$2"
    if ! echo "$haystack" | grep -qF "$needle"; then
        echo "FAIL: expected '$needle' in output: $haystack"
        exit 1
    fi
}

# --- resolve: no votes yet → permanent failure exit 2 ---
set +e
"$CHUMP_BIN" consensus resolve "$CORR_ID" >/dev/null 2>&1
RC=$?
set -e
if [[ "$RC" != "2" ]]; then
    echo "FAIL: expected exit 2 for corr_id with no votes, got $RC"
    exit 1
fi
echo "[test-chump-consensus] PASS — resolve with zero votes exits 2 (permanent)"

# --- seed 3 +1 and 1 -1 votes → PASSED ---
for i in 1 2 3; do
    printf '{"ts":"%s","event":"FEEDBACK","kind":"vote","corr_id":"%s","vote":1,"rationale":"yes %d","session":"s%d"}\n' \
        "$TS" "$CORR_ID" "$i" "$i" >> "$AMBIENT"
done
printf '{"ts":"%s","event":"FEEDBACK","kind":"vote","corr_id":"%s","vote":-1,"rationale":"no","session":"s4"}\n' \
    "$TS" "$CORR_ID" >> "$AMBIENT"

echo "[test-chump-consensus] running: chump consensus resolve $CORR_ID"
OUTPUT="$("$CHUMP_BIN" consensus resolve "$CORR_ID")"
echo "[test-chump-consensus] output: $OUTPUT"
assert_contains "verdict=PASSED" "$OUTPUT"
assert_contains "emitted kind=consensus_result" "$OUTPUT"

# consensus_result line must be present in ambient.jsonl.
if ! grep -q '"kind":"consensus_result"' "$AMBIENT"; then
    echo "FAIL: no kind=consensus_result event written to ambient.jsonl"
    exit 1
fi
echo "[test-chump-consensus] PASS — resolve emits kind=consensus_result on PASSED"

# --- idempotency: re-resolve must NOT emit a second consensus_result ---
BEFORE_COUNT="$(grep -c '"kind":"consensus_result"' "$AMBIENT")"
OUTPUT2="$("$CHUMP_BIN" consensus resolve "$CORR_ID")"
AFTER_COUNT="$(grep -c '"kind":"consensus_result"' "$AMBIENT")"
if [[ "$BEFORE_COUNT" != "$AFTER_COUNT" ]]; then
    echo "FAIL: re-resolve emitted a duplicate consensus_result ($BEFORE_COUNT -> $AFTER_COUNT)"
    exit 1
fi
assert_contains "already resolved" "$OUTPUT2"
echo "[test-chump-consensus] PASS — re-resolve is idempotent (no duplicate emit)"

# --- status: durable decision state must be queryable ---
echo "[test-chump-consensus] running: chump consensus status $CORR_ID"
STATUS_OUTPUT="$("$CHUMP_BIN" consensus status "$CORR_ID")"
echo "[test-chump-consensus] output: $STATUS_OUTPUT"
assert_contains "verdict=PASSED" "$STATUS_OUTPUT"
assert_contains "corr_id=$CORR_ID" "$STATUS_OUTPUT"
echo "[test-chump-consensus] PASS — status reports durable decision state"

# --- status --all must include the resolved corr_id ---
STATUS_ALL="$("$CHUMP_BIN" consensus status --all)"
assert_contains "$CORR_ID" "$STATUS_ALL"
echo "[test-chump-consensus] PASS — status --all includes resolved corr_id"

# --- status on an unresolved corr_id with only pending votes falls back to live tally ---
PENDING_ID="test-consensus-pending-$$"
printf '{"ts":"%s","event":"FEEDBACK","kind":"vote","corr_id":"%s","vote":1,"rationale":"yes","session":"s1"}\n' \
    "$TS" "$PENDING_ID" >> "$AMBIENT"
PENDING_OUTPUT="$("$CHUMP_BIN" consensus status "$PENDING_ID")"
assert_contains "NO_QUORUM" "$PENDING_OUTPUT"
assert_contains "pending" "$PENDING_OUTPUT"
echo "[test-chump-consensus] PASS — status falls back to live tally for unresolved corr_id"

echo "[test-chump-consensus] ALL PASS"
