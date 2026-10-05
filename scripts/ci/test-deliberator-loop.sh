#!/usr/bin/env bash
# scripts/ci/test-deliberator-loop.sh — CI test for deliberator-loop.sh (META-162)
#
# Seeds 3 fixture FEEDBACK proposals with mixed vote tallies in a tmp ambient,
# runs tick, and asserts correct consensus_result events were emitted.
#
# Fixture layout:
#   Proposal A (corr_id=TEST-A): 3 yes + 1 no  → PASSED
#   Proposal B (corr_id=TEST-B): 1 yes + 2 no  → FAILED
#   Proposal C (corr_id=TEST-C): 1 yes + 1 no  → NO_QUORUM (total=2 < 3), deadline not elapsed → no escalation
#
# Expected: 2 consensus_result events emitted (A=PASSED, B=FAILED); C left pending.
#
# Exit: 0 on all assertions passing, 1 on any failure.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
LOOP_SCRIPT="$REPO_ROOT/scripts/coord/deliberator-loop.sh"

if [[ ! -f "$LOOP_SCRIPT" ]]; then
    echo "FAIL: $LOOP_SCRIPT not found" >&2
    exit 1
fi

# ── Scratch space ─────────────────────────────────────────────────────────────

TMPDIR_TEST="$(mktemp -d /tmp/test-deliberator-XXXXXX)"
trap 'rm -rf "$TMPDIR_TEST"' EXIT

AMBIENT_FILE="$TMPDIR_TEST/ambient.jsonl"
LOCK_DIR="$TMPDIR_TEST/locks"
mkdir -p "$LOCK_DIR"

# CREDIBLE-179: _consensus_src() in deliberator-loop.sh prefers FEEDBACK_LOG
# over AMBIENT when FEEDBACK_LOG exists (default: .chump-locks/feedback.jsonl
# in whatever repo the script runs from). Without an explicit override this
# test silently read the real repo's production feedback.jsonl instead of
# the seeded fixture below — point it at a path that doesn't exist so the
# script's own fallback-to-AMBIENT logic kicks in.
CHUMP_FEEDBACK_LOG="$TMPDIR_TEST/feedback-unused.jsonl"
export CHUMP_FEEDBACK_LOG

_now_iso() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# Timestamps: proposals 20h ago (within 24h window).
# DEADLINE_PAST: 48h ago — ensures verdict resolves as PASSED/FAILED not EXTENDED.
# DEADLINE_FUTURE: 30h from now — keeps TEST-C in NO_QUORUM without grace-window escalation.
# Use python3 for epoch arithmetic to avoid macOS/GNU date compat issues.
_ts_offset() {
    # $1 = offset in seconds (positive = future, negative = past)
    python3 -W ignore -c "
import datetime, sys
offset = int(sys.argv[1])
dt = datetime.datetime.now(datetime.timezone.utc) + datetime.timedelta(seconds=offset)
print(dt.strftime('%Y-%m-%dT%H:%M:%SZ'))
" "$1"
}
PAST_TS_20H="$(_ts_offset $(( -20 * 3600 )))"
DEADLINE_PAST="$(_ts_offset $(( -48 * 3600 )))"
DEADLINE_FUTURE="$(_ts_offset $(( 30 * 3600 )))"

# ── Seed fixture events ───────────────────────────────────────────────────────

# Proposal A — will be PASSED (3 yes, 1 no)
cat >> "$AMBIENT_FILE" <<EOF
{"ts":"$PAST_TS_20H","event":"FEEDBACK","kind":"proposal","corr_id":"TEST-A","deadline":"$DEADLINE_PAST","session":"agent-1","title":"Proposal A"}
{"ts":"$PAST_TS_20H","event":"FEEDBACK","kind":"vote","corr_id":"TEST-A","vote":1,"session":"agent-1","rationale":"ship it"}
{"ts":"$PAST_TS_20H","event":"FEEDBACK","kind":"vote","corr_id":"TEST-A","vote":1,"session":"agent-2","rationale":"looks good"}
{"ts":"$PAST_TS_20H","event":"FEEDBACK","kind":"vote","corr_id":"TEST-A","vote":1,"session":"agent-3","rationale":"approved"}
{"ts":"$PAST_TS_20H","event":"FEEDBACK","kind":"vote","corr_id":"TEST-A","vote":-1,"session":"agent-4","rationale":"needs work"}
EOF

# Proposal B — will be FAILED (1 yes, 2 no)
cat >> "$AMBIENT_FILE" <<EOF
{"ts":"$PAST_TS_20H","event":"FEEDBACK","kind":"proposal","corr_id":"TEST-B","deadline":"$DEADLINE_PAST","session":"agent-1","title":"Proposal B"}
{"ts":"$PAST_TS_20H","event":"FEEDBACK","kind":"vote","corr_id":"TEST-B","vote":1,"session":"agent-1","rationale":"yes"}
{"ts":"$PAST_TS_20H","event":"FEEDBACK","kind":"vote","corr_id":"TEST-B","vote":-1,"session":"agent-2","rationale":"no"}
{"ts":"$PAST_TS_20H","event":"FEEDBACK","kind":"vote","corr_id":"TEST-B","vote":-1,"session":"agent-3","rationale":"no"}
EOF

# Proposal C — will be NO_QUORUM (1 yes, 1 no, total=2) + deadline in future → no escalation
cat >> "$AMBIENT_FILE" <<EOF
{"ts":"$PAST_TS_20H","event":"FEEDBACK","kind":"proposal","corr_id":"TEST-C","deadline":"$DEADLINE_FUTURE","session":"agent-1","title":"Proposal C"}
{"ts":"$PAST_TS_20H","event":"FEEDBACK","kind":"vote","corr_id":"TEST-C","vote":1,"session":"agent-1","rationale":"yes"}
{"ts":"$PAST_TS_20H","event":"FEEDBACK","kind":"vote","corr_id":"TEST-C","vote":-1,"session":"agent-2","rationale":"no"}
EOF

echo "=== Fixture seeded: $(wc -l < "$AMBIENT_FILE") lines in $AMBIENT_FILE ==="

# ── Run tick ──────────────────────────────────────────────────────────────────

echo
echo "=== Running deliberator-loop.sh tick ==="
CHUMP_FLEET_RECV_SIDE_V0=1 \
CHUMP_AMBIENT_LOG="$AMBIENT_FILE" \
CHUMP_SESSION_ID="test-deliberator-$$" \
CHUMP_PROPOSAL_WINDOW_HOURS=24 \
CHUMP_NO_QUORUM_GRACE_HOURS=24 \
    bash "$LOOP_SCRIPT" tick || true  # exit 1 = quiet is OK; we assert on file contents

echo
echo "=== Asserting consensus_result events ==="

# ── Assertions ────────────────────────────────────────────────────────────────

FAIL=0

# Count total consensus_result lines emitted.
# Use grep -c with a fallback to 0; strip any whitespace/newlines for safe integer compare.
result_count="$(grep -c '"kind":"consensus_result"' "$AMBIENT_FILE" 2>/dev/null || true)"
result_count="${result_count//[$'\t\r\n ']}"   # strip whitespace
result_count="${result_count:-0}"
echo "consensus_result count: ${result_count} (expected 2)"
if [[ "${result_count}" -ne 2 ]]; then
    echo "FAIL: expected 2 consensus_result events, got ${result_count}" >&2
    FAIL=1
fi

# Assert TEST-A is PASSED.
if grep -q '"corr_id":"TEST-A".*"verdict":"PASSED"' "$AMBIENT_FILE" \
    || grep -q '"verdict":"PASSED".*"corr_id":"TEST-A"' "$AMBIENT_FILE"; then
    echo "PASS: TEST-A verdict=PASSED"
else
    echo "FAIL: TEST-A did not get verdict=PASSED" >&2
    FAIL=1
fi

# Assert TEST-B is FAILED.
if grep -q '"corr_id":"TEST-B".*"verdict":"FAILED"' "$AMBIENT_FILE" \
    || grep -q '"verdict":"FAILED".*"corr_id":"TEST-B"' "$AMBIENT_FILE"; then
    echo "PASS: TEST-B verdict=FAILED"
else
    echo "FAIL: TEST-B did not get verdict=FAILED" >&2
    FAIL=1
fi

# Assert TEST-C has NO consensus_result (still pending, deadline in future + grace not elapsed).
if grep -q '"corr_id":"TEST-C".*"kind":"consensus_result"' "$AMBIENT_FILE" \
    || grep -q '"kind":"consensus_result".*"corr_id":"TEST-C"' "$AMBIENT_FILE"; then
    echo "FAIL: TEST-C should NOT have a consensus_result yet" >&2
    FAIL=1
else
    echo "PASS: TEST-C has no premature consensus_result"
fi

# Assert vote_counts field is present in results (AC: emit vote_counts).
if grep -q '"vote_counts"' "$AMBIENT_FILE"; then
    echo "PASS: vote_counts field present in consensus_result"
else
    echo "FAIL: vote_counts field missing from consensus_result" >&2
    FAIL=1
fi

# Assert voters_list field is present.
if grep -q '"voters_list"' "$AMBIENT_FILE"; then
    echo "PASS: voters_list field present in consensus_result"
else
    echo "FAIL: voters_list field missing from consensus_result" >&2
    FAIL=1
fi

# Idempotency: run tick again, assert count does NOT increase.
echo
echo "=== Idempotency check: running tick again ==="
CHUMP_FLEET_RECV_SIDE_V0=1 \
CHUMP_AMBIENT_LOG="$AMBIENT_FILE" \
CHUMP_SESSION_ID="test-deliberator-idem-$$" \
CHUMP_PROPOSAL_WINDOW_HOURS=24 \
CHUMP_NO_QUORUM_GRACE_HOURS=24 \
    bash "$LOOP_SCRIPT" tick || true

result_count_after="$(grep -c '"kind":"consensus_result"' "$AMBIENT_FILE" 2>/dev/null || true)"
result_count_after="${result_count_after//[$'\t\r\n ']}"
result_count_after="${result_count_after:-0}"
echo "consensus_result count after 2nd tick: ${result_count_after} (expected 2)"
if [[ "${result_count_after}" -ne 2 ]]; then
    echo "FAIL: idempotency broken — count changed from 2 to ${result_count_after}" >&2
    FAIL=1
else
    echo "PASS: idempotency guard held"
fi

# Feature flag explicitly off (CHUMP_FLEET_RECV_SIDE_V0=0): run tick, assert
# no new results. CREDIBLE-179 flipped this flag to default-ON (opt-out)
# matching `chump vote`'s polarity, so the meaningful negative case is now
# "explicitly disabled", not merely "unset".
echo
echo "=== Feature flag explicitly off (CHUMP_FLEET_RECV_SIDE_V0=0) ==="
AMBIENT_FLAGOFF="$TMPDIR_TEST/ambient-flagoff.jsonl"
cp "$AMBIENT_FILE" "$AMBIENT_FLAGOFF"
# Remove the already-emitted results so we'd detect if tick wrongly emits new ones.
grep -v '"kind":"consensus_result"' "$AMBIENT_FLAGOFF" > "$TMPDIR_TEST/stripped.jsonl" || true
cp "$TMPDIR_TEST/stripped.jsonl" "$AMBIENT_FLAGOFF"

CHUMP_FLEET_RECV_SIDE_V0=0 \
CHUMP_AMBIENT_LOG="$AMBIENT_FLAGOFF" \
CHUMP_SESSION_ID="test-deliberator-flag-$$" \
CHUMP_PROPOSAL_WINDOW_HOURS=24 \
    bash "$LOOP_SCRIPT" tick || true

flagoff_count="$(grep -c '"kind":"consensus_result"' "$AMBIENT_FLAGOFF" 2>/dev/null || true)"
flagoff_count="${flagoff_count//[$'\t\r\n ']}"
flagoff_count="${flagoff_count:-0}"
echo "consensus_result count (flag=0): ${flagoff_count} (expected 0)"
if [[ "${flagoff_count}" -ne 0 ]]; then
    echo "FAIL: feature flag=0 but consensus_result was emitted" >&2
    FAIL=1
else
    echo "PASS: feature flag=0 — no consensus_result emitted"
fi

# Feature flag UNSET (CREDIBLE-179 default): run tick, assert it DOES do
# real work — this is the exact regression this gap fixes (a session that
# never sets CHUMP_FLEET_RECV_SIDE_V0 must still get real tallying, not a
# silent heartbeat-only no-op).
echo
echo "=== Feature flag unset (CREDIBLE-179 default-on) ==="
AMBIENT_DEFAULT="$TMPDIR_TEST/ambient-default.jsonl"
cp "$TMPDIR_TEST/stripped.jsonl" "$AMBIENT_DEFAULT"

env -u CHUMP_FLEET_RECV_SIDE_V0 \
CHUMP_AMBIENT_LOG="$AMBIENT_DEFAULT" \
CHUMP_SESSION_ID="test-deliberator-default-$$" \
CHUMP_PROPOSAL_WINDOW_HOURS=24 \
CHUMP_FEEDBACK_LOG="$CHUMP_FEEDBACK_LOG" \
    bash "$LOOP_SCRIPT" tick || true

default_count="$(grep -c '"kind":"consensus_result"' "$AMBIENT_DEFAULT" 2>/dev/null || true)"
default_count="${default_count//[$'\t\r\n ']}"
default_count="${default_count:-0}"
echo "consensus_result count (flag unset): ${default_count} (expected 2)"
if [[ "${default_count}" -ne 2 ]]; then
    echo "FAIL: flag unset should default ON and tally real proposals, got ${default_count}" >&2
    FAIL=1
else
    echo "PASS: flag unset — default-on tallied real proposals"
fi

# ── Summary ───────────────────────────────────────────────────────────────────

echo
if [[ "$FAIL" -eq 0 ]]; then
    echo "=== ALL ASSERTIONS PASSED ==="
    exit 0
else
    echo "=== ${FAIL} ASSERTION(S) FAILED ===" >&2
    echo "Ambient file contents for debugging:" >&2
    cat "$AMBIENT_FILE" >&2
    exit 1
fi
