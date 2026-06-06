#!/usr/bin/env bash
# test-a2a-always-on.sh — INFRA-2515 (operator mandate 2026-06-05)
#
# The A2A consensus layer must ALWAYS be on AND in use. This guards the three
# mechanisms that enforce it:
#   1. fleet-doctor's `a2a-consensus` check is defined + wired into the run block
#      (so a dormant consensus layer turns fleet-doctor RED → self-doctor sees it).
#   2. The deliberator exits 0 on a successful-but-quiet tick — the old
#      `return 1` for "all proposals still in NO_QUORUM grace" made launchd record
#      last-exit-code=1 and polluted daemon-health scans (a healthy tallier looked
#      dead).
#   3. The deliberator actively NUDGES curators to vote on a starved NO_QUORUM
#      proposal (rate-limited) instead of waiting silently for the grace window to
#      expire and paging the operator — the "always in use" driver.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
PASS=0
FAIL=0
ok()  { echo "  PASS: $1"; PASS=$((PASS+1)); }
bad() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

DOCTOR="$REPO_ROOT/scripts/coord/fleet-doctor-strict.sh"
DELIB="$REPO_ROOT/scripts/coord/deliberator-loop.sh"

echo "=== INFRA-2515: A2A always-on ==="

# ── 1. fleet-doctor enforcement is wired ──────────────────────────────────────
if grep -q 'check_a2a_consensus()' "$DOCTOR"; then
    ok "fleet-doctor defines check_a2a_consensus"
else
    bad "fleet-doctor does NOT define check_a2a_consensus"
fi
if grep -qE '^check_a2a_consensus$' "$DOCTOR"; then
    ok "fleet-doctor invokes check_a2a_consensus in the run block"
else
    bad "fleet-doctor does NOT invoke check_a2a_consensus"
fi
# The check must fail (not just warn) when the recv-side flag is off.
if grep -q 'register_check "a2a-consensus" "fail"' "$DOCTOR"; then
    ok "a2a-consensus check fails on dormancy (force/mandate)"
else
    bad "a2a-consensus check never fails — enforcement is toothless"
fi

# ── 2. deliberator nudge is wired ─────────────────────────────────────────────
if grep -q '_nudge_curators_to_vote()' "$DELIB"; then
    ok "deliberator defines _nudge_curators_to_vote"
else
    bad "deliberator does NOT define _nudge_curators_to_vote"
fi
if grep -q '_nudge_curators_to_vote "$line_corr"' "$DELIB"; then
    ok "deliberator calls the nudge in the NO_QUORUM grace branch"
else
    bad "deliberator does NOT call the nudge"
fi

# ── 3. behavioral: tick exits 0 + nudges a starved proposal ───────────────────
TMP="$(mktemp -d -t a2a-always-on.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/.chump-locks"
NOW_ISO="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
CORR="test-a2a-alwayson-$$"
# A fresh proposal with zero votes → NO_QUORUM, within the 24h window, deadline
# defaults to ts+48h (future) → "grace remaining" branch → should nudge.
printf '{"ts":"%s","event":"FEEDBACK","kind":"proposal","corr_id":"%s","subject":"a2a always-on test","session":"test"}\n' \
    "$NOW_ISO" "$CORR" > "$TMP/feedback.jsonl"

# The nudge stamp lands in the deliberator's LOCK_DIR = MAIN_REPO/.chump-locks.
# In a linked worktree MAIN_REPO resolves (via git-common-dir) to the main
# checkout, not the worktree; in CI (a plain clone) it equals REPO_ROOT. Compute
# it the same way the deliberator does so this test is correct in both.
_git_common="$(git -C "$REPO_ROOT" rev-parse --git-common-dir 2>/dev/null || echo ".git")"
if [[ "$_git_common" == ".git" ]]; then
    MAIN_REPO="$REPO_ROOT"
else
    MAIN_REPO="$(cd "$_git_common/.." && pwd)"
fi
STAMP="$MAIN_REPO/.chump-locks/.a2a-nudge-${CORR}.stamp"
rm -f "$STAMP"

set +e
CHUMP_FLEET_RECV_SIDE_V0=1 \
CHUMP_FEEDBACK_LOG="$TMP/feedback.jsonl" \
CHUMP_AMBIENT_LOG="$TMP/.chump-locks/ambient.jsonl" \
CHUMP_A2A_NUDGE_COOLDOWN_HOURS=6 \
    bash "$DELIB" tick >/dev/null 2>&1
rc=$?
set -e 2>/dev/null || true

if [[ "$rc" -eq 0 ]]; then
    ok "deliberator tick exits 0 on a quiet (all-NO_QUORUM) tick (exit-fix)"
else
    bad "deliberator tick exited $rc (expected 0 — exit-fix regressed)"
fi

if [[ -f "$STAMP" ]]; then
    ok "deliberator nudged the starved proposal (rate-limit stamp created)"
    rm -f "$STAMP"
else
    bad "deliberator did NOT nudge the starved proposal (no stamp for $CORR)"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
if [[ "$FAIL" -gt 0 ]]; then
    exit 1
fi
exit 0
