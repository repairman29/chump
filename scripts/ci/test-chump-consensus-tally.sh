#!/usr/bin/env bash
# META-159 AC6: test-chump-consensus-tally.sh
# Seed 3 +1 and 1 -1 and 1 0 vote events with same corr_id in a tmp
# ambient.jsonl, run `chump consensus-tally --corr-id <id> --all`, and
# assert output shows yes=3, no=1, abstain=1, verdict=PASSED.
set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
CHUMP_BIN="${CHUMP_BIN:-$REPO_ROOT/target/debug/chump}"

if [[ ! -x "$CHUMP_BIN" ]]; then
    echo "[test-chump-consensus-tally] building chump binary..."
    cargo build --manifest-path "$REPO_ROOT/Cargo.toml" --bin chump --quiet
fi

TMPDIR_TEST="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_TEST"' EXIT

AMBIENT="$TMPDIR_TEST/ambient.jsonl"
export CHUMP_AMBIENT_LOG="$AMBIENT"
export CHUMP_REPO_ROOT="$REPO_ROOT"

CORR_ID="test-tally-$$"
TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# Seed 3 +1 votes.
for i in 1 2 3; do
    printf '{"ts":"%s","event":"FEEDBACK","kind":"vote","corr_id":"%s","vote":1,"rationale":"yes vote %d","session":"test-session-%d"}\n' \
        "$TS" "$CORR_ID" "$i" "$i" >> "$AMBIENT"
done

# Seed 1 -1 vote.
printf '{"ts":"%s","event":"FEEDBACK","kind":"vote","corr_id":"%s","vote":-1,"rationale":"no vote","session":"test-session-4"}\n' \
    "$TS" "$CORR_ID" >> "$AMBIENT"

# Seed 1 0 (abstain) vote.
printf '{"ts":"%s","event":"FEEDBACK","kind":"vote","corr_id":"%s","vote":0,"rationale":"abstain","session":"test-session-5"}\n' \
    "$TS" "$CORR_ID" >> "$AMBIENT"

# Also add a noise event with a different corr_id to verify filtering.
printf '{"ts":"%s","event":"FEEDBACK","kind":"vote","corr_id":"other-id","vote":1,"rationale":"noise","session":"test-noise"}\n' \
    "$TS" >> "$AMBIENT"

# Also add a non-vote event (different kind) that must be ignored.
# Use kind=retro (existing registered kind) so the event-registry hook
# doesn't flag a new kind from this test fixture line.
NON_VOTE_KIND="retro"
printf '{"ts":"%s","event":"FEEDBACK","kind":"%s","corr_id":"%s","subject":"should be ignored"}\n' \
    "$TS" "$NON_VOTE_KIND" "$CORR_ID" >> "$AMBIENT"

echo "[test-chump-consensus-tally] seeded ambient.jsonl with 5 vote events (3+1 / 1-1 / 1×0) + 1 noise"
echo "[test-chump-consensus-tally] running: chump consensus-tally --corr-id $CORR_ID --all"

OUTPUT="$("$CHUMP_BIN" consensus-tally --corr-id "$CORR_ID" --all)"
echo "[test-chump-consensus-tally] output: $OUTPUT"

assert_contains() {
    local needle="$1" haystack="$2"
    if ! echo "$haystack" | grep -qF "$needle"; then
        echo "FAIL: expected '$needle' in output: $haystack"
        exit 1
    fi
}

assert_contains "yes=3"       "$OUTPUT"
assert_contains "no=1"        "$OUTPUT"
assert_contains "abstain=1"   "$OUTPUT"
assert_contains "total=5"     "$OUTPUT"
assert_contains "verdict=PASSED" "$OUTPUT"

# Verify the noise corr_id does NOT appear in the filtered output.
if echo "$OUTPUT" | grep -qF "other-id"; then
    echo "FAIL: noise corr_id 'other-id' appeared in filtered output"
    exit 1
fi

echo "[test-chump-consensus-tally] PASS — yes=3 no=1 abstain=1 total=5 verdict=PASSED"

# --- Secondary test: NO_QUORUM when only 2 votes ---
echo ""
echo "[test-chump-consensus-tally] secondary test: NO_QUORUM with 2 votes"

AMBIENT2="$TMPDIR_TEST/ambient2.jsonl"
export CHUMP_AMBIENT_LOG="$AMBIENT2"
CORR2="no-quorum-$$"

for i in 1 2; do
    printf '{"ts":"%s","event":"FEEDBACK","kind":"vote","corr_id":"%s","vote":1,"rationale":"yes","session":"s%d"}\n' \
        "$TS" "$CORR2" "$i" >> "$AMBIENT2"
done

OUTPUT2="$("$CHUMP_BIN" consensus-tally --corr-id "$CORR2" --all)"
echo "[test-chump-consensus-tally] output: $OUTPUT2"
assert_contains "verdict=NO_QUORUM" "$OUTPUT2"

echo "[test-chump-consensus-tally] PASS — NO_QUORUM confirmed for 2 votes"

# --- Tertiary test: feature flag unset → vote command prints message ---
echo ""
echo "[test-chump-consensus-tally] tertiary: chump vote with flag unset prints message"
unset CHUMP_FLEET_RECV_SIDE_V0
VOTE_OUT="$("$CHUMP_BIN" vote META-999 +1 --reason "test" 2>&1 || true)"
if ! echo "$VOTE_OUT" | grep -qF "feature flag off"; then
    echo "FAIL: expected 'feature flag off' message, got: $VOTE_OUT"
    exit 1
fi
echo "[test-chump-consensus-tally] PASS — feature flag off message confirmed"

# --- CREDIBLE-082: vote-weighting smoke test ---
# Scenario: 1 original FEEDBACK proposal + 5 reactions with parent_corr_id set.
# Expected: raw=6, weighted=1.0+5×0.3=2.5, echo-warn fires (2.5/6≈0.417 < 0.5).
echo ""
echo "[test-chump-consensus-tally] CREDIBLE-082 weighting: 1 original + 5 reactions"

AMBIENT3="$TMPDIR_TEST/ambient3.jsonl"
export CHUMP_AMBIENT_LOG="$AMBIENT3"
PROP_ID="credible-082-prop-$$"
export CHUMP_CONSENSUS_REACT_WEIGHT="0.3"

# 1 original vote (no parent_corr_id field).
printf '{"ts":"%s","event":"FEEDBACK","kind":"vote","corr_id":"%s","vote":1,"rationale":"proposal author","session":"s-orig"}\n' \
    "$TS" "$PROP_ID" >> "$AMBIENT3"

# 5 reactions (parent_corr_id set to the proposal's corr_id).
for i in 1 2 3 4 5; do
    printf '{"ts":"%s","event":"FEEDBACK","kind":"vote","corr_id":"%s","parent_corr_id":"%s","vote":1,"rationale":"reaction %d","session":"s-react-%d"}\n' \
        "$TS" "$PROP_ID" "$PROP_ID" "$i" "$i" >> "$AMBIENT3"
done

OUTPUT3="$("$CHUMP_BIN" consensus-tally --corr-id "$PROP_ID" --all)"
echo "[test-chump-consensus-tally] CREDIBLE-082 output: $OUTPUT3"

# Assert raw count = 6.
assert_contains "total=6" "$OUTPUT3"

# Assert weighted = 2.50 (1 + 5×0.3).
assert_contains "weighted=2.50" "$OUTPUT3"

# Assert echo-warn prefix fires (ratio 2.5/6 ≈ 0.417 < 0.5 threshold).
if ! echo "$OUTPUT3" | grep -qF "[echo-warn]"; then
    echo "FAIL: expected '[echo-warn]' prefix in output (weighted/raw below threshold)"
    exit 1
fi

echo "[test-chump-consensus-tally] CREDIBLE-082 PASS — raw=6 weighted=2.50 echo-warn fired"

# --- CREDIBLE-082: no echo-warn when all originals ---
echo ""
echo "[test-chump-consensus-tally] CREDIBLE-082 no-echo-warn: all originals"

AMBIENT4="$TMPDIR_TEST/ambient4.jsonl"
export CHUMP_AMBIENT_LOG="$AMBIENT4"
ORIG_ID="credible-082-orig-$$"

for i in 1 2 3 4 5 6; do
    printf '{"ts":"%s","event":"FEEDBACK","kind":"vote","corr_id":"%s","vote":1,"rationale":"orig %d","session":"so-%d"}\n' \
        "$TS" "$ORIG_ID" "$i" "$i" >> "$AMBIENT4"
done

OUTPUT4="$("$CHUMP_BIN" consensus-tally --corr-id "$ORIG_ID" --all)"
echo "[test-chump-consensus-tally] CREDIBLE-082 no-warn output: $OUTPUT4"

assert_contains "total=6"       "$OUTPUT4"
assert_contains "weighted=6.00" "$OUTPUT4"

if echo "$OUTPUT4" | grep -qF "[echo-warn]"; then
    echo "FAIL: '[echo-warn]' should NOT appear when all votes are originals"
    exit 1
fi

echo "[test-chump-consensus-tally] CREDIBLE-082 PASS — all originals, no echo-warn"
