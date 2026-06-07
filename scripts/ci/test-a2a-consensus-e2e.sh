#!/usr/bin/env bash
# test-a2a-consensus-e2e.sh — CREDIBLE-122
#
# The REAL end-to-end consensus path: `chump vote` (3 distinct sessions) ->
# deliberator tick -> consensus_result emitted. THIS IS THE TEST THE BUG EVADED.
#
# Background: `chump vote` writes the vote as kind=vote to ambient.jsonl AND a
# kind=preference mirror to feedback.jsonl. The deliberator's tally gated on a
# broken `consensus-tally --help | grep corr-id` check (never matched) and fell
# back to scanning feedback.jsonl for kind=vote — which isn't there (it's
# kind=preference) — so it tallied 0 and consensus_result was 0 FLEET-WIDE for
# the entire history, while test-deliberator-tick-emits.sh stayed green because
# it HAND-WRITES kind=vote events the real `chump vote` never produces.
#
# This test refuses to repeat that mistake: it casts votes with the REAL `chump
# vote` tool and runs the REAL deliberator, and asserts consensus_result is
# actually emitted with verdict=PASSED. If the deliberator can't tally real
# votes, this FAILS.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
PASS=0
FAIL=0
ok()  { echo "  PASS: $1"; PASS=$((PASS+1)); }
bad() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

echo "=== CREDIBLE-122: A2A consensus REAL end-to-end ==="
if ! command -v chump >/dev/null 2>&1; then
    echo "  SKIP: chump binary not on PATH"
    exit 0
fi

TMP="$(mktemp -d -t a2a-e2e.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT
AMB="$TMP/ambient.jsonl"
FB="$TMP/feedback.jsonl"
: > "$AMB"
: > "$FB"

NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
PAST="$(date -u -v-10M +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d '10 minutes ago' +%Y-%m-%dT%H:%M:%SZ)"
CORR="a2a-e2e-$$"

# A real proposal with an already-closed voting window so the verdict is
# decidable on this tick (deadline in the past → not EXTENDED).
printf '{"ts":"%s","event":"FEEDBACK","kind":"proposal","corr_id":"%s","subject":"e2e consensus test","deadline":"%s","session":"test"}\n' \
    "$NOW" "$CORR" "$PAST" >> "$FB"

# Cast 3 REAL votes via the real tool, each a distinct session. vote.rs writes
# the kind=vote line to CHUMP_AMBIENT_LOG (sandboxed here). broadcast.sh also
# mirrors a harmless kind=preference into the repo's real .chump-locks; in CI
# that checkout is ephemeral, and the mirror is not a proposal so it triggers no
# check.
for s in alpha beta gamma; do
    CHUMP_FLEET_RECV_SIDE_V0=1 \
    CHUMP_AMBIENT_LOG="$AMB" \
    CHUMP_FEEDBACK_LOG="$FB" \
    CHUMP_SESSION_ID="e2e-voter-$s" \
        chump vote "$CORR" +1 --reason "e2e vote $s" >/dev/null 2>&1 || true
done

# The real vote tool must produce kind=vote in ambient — the exact shape the
# tally depends on. If this is < 3 the vote tool's output drifted.
vc="$(grep -c '"kind":"vote"' "$AMB" 2>/dev/null || echo 0)"
if [[ "$vc" -ge 3 ]]; then
    ok "3 real \`chump vote\` events landed in ambient as kind=vote (got $vc)"
else
    bad "expected >=3 kind=vote in ambient from real chump vote, got $vc"
fi

# Run the REAL deliberator against the sandbox. With the CREDIBLE-122 fix it
# tallies via consensus-tally (ambient kind=vote) -> PASSED -> consensus_result.
CHUMP_FLEET_RECV_SIDE_V0=1 \
CHUMP_AMBIENT_LOG="$AMB" \
CHUMP_FEEDBACK_LOG="$FB" \
    timeout 40 bash "$REPO_ROOT/scripts/coord/deliberator-loop.sh" tick >/dev/null 2>&1 || true

if grep "$CORR" "$AMB" 2>/dev/null | grep -q '"kind":"consensus_result"'; then
    ok "deliberator emitted consensus_result for the REAL-vote proposal"
    if grep "$CORR" "$AMB" | grep '"kind":"consensus_result"' | grep -q 'PASSED'; then
        ok "verdict=PASSED — 3 real votes were actually tallied"
    else
        bad "consensus_result emitted but verdict is not PASSED (tally undercounted real votes)"
    fi
else
    bad "NO consensus_result emitted — the real vote->tally->emit path is broken (CREDIBLE-122 regression)"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
if [[ "$FAIL" -gt 0 ]]; then
    exit 1
fi
exit 0
