#!/usr/bin/env bash
# INFRA-2159 (META-125/C8) smoke test for chump-consensus-aggregator-daemon.
#
# Seeds ambient.jsonl with a quorum-reaching set of kind=vote events (2
# high-confidence yes, 1 low-confidence no) for one corr_id, runs the
# daemon with --once, and asserts:
#   1. A kind=consensus_resolved event is appended with decision=Proceed
#      and the raw votes_for/votes_against counts EVENT_REGISTRY.yaml
#      requires.
#   2. The corr_id is idempotent: a second --once pass does not duplicate
#      the consensus_resolved line.
#   3. .chump/state.db has a matching consensus_decisions row.
set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
TARGET_DIR="${CARGO_TARGET_DIR:-$REPO_ROOT/target}"
DAEMON_BIN="${DAEMON_BIN:-$TARGET_DIR/debug/chump-consensus-aggregator-daemon}"

if [[ ! -x "$DAEMON_BIN" ]]; then
    echo "[test-chump-consensus-aggregator-daemon] building daemon binary..."
    cargo build --manifest-path "$REPO_ROOT/Cargo.toml" --bin chump-consensus-aggregator-daemon --quiet
fi

TMPDIR_TEST="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_TEST"' EXIT

AMBIENT="$TMPDIR_TEST/ambient.jsonl"
STATE_DB="$TMPDIR_TEST/state.db"
CORR_ID="test-aggregator-$$"
TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# 2 high-confidence yes votes + 1 low-confidence no vote → quorum=3 reached,
# weighted decision should still be Proceed (2*1.0 > 1*0.2).
printf '{"ts":"%s","event":"FEEDBACK","kind":"vote","corr_id":"%s","vote":1,"rationale":"yes 1","confidence":100,"session":"s1"}\n' \
    "$TS" "$CORR_ID" >> "$AMBIENT"
printf '{"ts":"%s","event":"FEEDBACK","kind":"vote","corr_id":"%s","vote":1,"rationale":"yes 2","confidence":90,"session":"s2"}\n' \
    "$TS" "$CORR_ID" >> "$AMBIENT"
printf '{"ts":"%s","event":"FEEDBACK","kind":"vote","corr_id":"%s","vote":-1,"rationale":"no, low confidence","confidence":20,"session":"s3"}\n' \
    "$TS" "$CORR_ID" >> "$AMBIENT"

# Noise: a different corr_id with only 1 vote — must stay pending (no event).
printf '{"ts":"%s","event":"FEEDBACK","kind":"vote","corr_id":"other-id","vote":1,"rationale":"noise","confidence":100,"session":"s4"}\n' \
    "$TS" >> "$AMBIENT"

echo "[test-chump-consensus-aggregator-daemon] running first --once pass"
"$DAEMON_BIN" --once --ambient "$AMBIENT" --state-db "$STATE_DB" --quorum 3

FAIL=0
assert_contains() {
    local needle="$1" haystack="$2" label="$3"
    if echo "$haystack" | grep -qF "$needle"; then
        echo "  PASS: $label"
    else
        echo "  FAIL: $label — expected to find '$needle'"
        FAIL=1
    fi
}

RESOLVED_LINES="$(grep '"kind":"consensus_resolved"' "$AMBIENT" || true)"
CORR_LINE="$(echo "$RESOLVED_LINES" | grep "\"corr_id\":\"$CORR_ID\"" || true)"

if [[ -z "$CORR_LINE" ]]; then
    echo "  FAIL: no consensus_resolved event emitted for $CORR_ID"
    FAIL=1
else
    assert_contains '"decision":"Proceed"' "$CORR_LINE" "decision=Proceed"
    assert_contains '"votes_for":2' "$CORR_LINE" "votes_for=2"
    assert_contains '"votes_against":1' "$CORR_LINE" "votes_against=1"
    assert_contains '"resolved_reason":"quorum_reached"' "$CORR_LINE" "resolved_reason=quorum_reached"
fi

OTHER_LINE="$(echo "$RESOLVED_LINES" | grep '"corr_id":"other-id"' || true)"
if [[ -n "$OTHER_LINE" ]]; then
    echo "  FAIL: other-id resolved before reaching quorum (1 vote < quorum 3)"
    FAIL=1
else
    echo "  PASS: other-id stayed pending (no premature resolution)"
fi

echo "[test-chump-consensus-aggregator-daemon] verifying state.db row"
ROW_COUNT="$(sqlite3 "$STATE_DB" "SELECT COUNT(*) FROM consensus_decisions WHERE corr_id='$CORR_ID';")"
if [[ "$ROW_COUNT" == "1" ]]; then
    echo "  PASS: consensus_decisions has 1 row for $CORR_ID"
else
    echo "  FAIL: expected 1 consensus_decisions row for $CORR_ID, got $ROW_COUNT"
    FAIL=1
fi

echo "[test-chump-consensus-aggregator-daemon] running second --once pass (idempotency check)"
"$DAEMON_BIN" --once --ambient "$AMBIENT" --state-db "$STATE_DB" --quorum 3

RESOLVED_COUNT_AFTER="$(grep -c '"kind":"consensus_resolved"' "$AMBIENT" || true)"
if [[ "$RESOLVED_COUNT_AFTER" == "1" ]]; then
    echo "  PASS: idempotent — still exactly 1 consensus_resolved line after 2nd pass"
else
    echo "  FAIL: expected exactly 1 consensus_resolved line total, got $RESOLVED_COUNT_AFTER"
    FAIL=1
fi

if [[ "$FAIL" -eq 0 ]]; then
    echo "[test-chump-consensus-aggregator-daemon] ALL CHECKS PASSED"
    exit 0
else
    echo "[test-chump-consensus-aggregator-daemon] SOME CHECKS FAILED"
    exit 1
fi
