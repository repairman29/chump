#!/usr/bin/env bash
# INFRA-813: verify that gap_reserve_cross_host_race test does not pollute
# live worktrees with bot-identity commits (chump-dispatch@chump.bot).
#
# Two checks:
#   1. The pre-push hook unsets GIT_AUTHOR_EMAIL before cargo test.
#   2. The cross-host race test passes CHUMP_RESERVE_NO_AUTOSTAGE=1.
#
# Usage: bash scripts/ci/test-gap-reserve-race-isolation.sh
set -euo pipefail

PASS=0
FAIL=0

ok()   { echo "  OK  $1"; PASS=$((PASS+1)); }
fail() { echo " FAIL  $1"; FAIL=$((FAIL+1)); }

# ── Check 1: pre-push hook unsets bot identity ───────────────────────────────
HOOK="scripts/git-hooks/pre-push"
if [[ ! -f "$HOOK" ]]; then
    fail "pre-push hook not found at $HOOK"
else
    if grep -q 'unset GIT_AUTHOR_EMAIL GIT_COMMITTER_EMAIL' "$HOOK"; then
        ok "pre-push hook unsets GIT_AUTHOR_EMAIL before cargo test"
    else
        fail "pre-push hook is missing 'unset GIT_AUTHOR_EMAIL GIT_COMMITTER_EMAIL' (INFRA-813)"
    fi
fi

# ── Check 2: cross-host race test sets CHUMP_RESERVE_NO_AUTOSTAGE ────────────
RACE_TEST="tests/gap_reserve_cross_host_race.rs"
if [[ ! -f "$RACE_TEST" ]]; then
    fail "race test not found at $RACE_TEST"
else
    if grep -q 'CHUMP_RESERVE_NO_AUTOSTAGE' "$RACE_TEST"; then
        ok "cross-host race test passes CHUMP_RESERVE_NO_AUTOSTAGE=1"
    else
        fail "$RACE_TEST is missing CHUMP_RESERVE_NO_AUTOSTAGE env var (INFRA-813)"
    fi
fi

# ── Summary ──────────────────────────────────────────────────────────────────
echo ""
echo "Results: $PASS passed, $FAIL failed"
if [[ "$FAIL" -gt 0 ]]; then
    echo "INFRA-813 isolation checks failed — see above for details."
    exit 1
fi
echo "INFRA-813 isolation checks passed."
