#!/usr/bin/env bash
# scripts/ci/test-install-node-housekeeping.sh — RESILIENT-341
#
# Verifies that the "reviver" organ (post-push-integrity-watch.sh — reopens
# closed-but-gap-open fleet PRs that were wrongly trashed by a stale-base
# auto-close) is wired into install-node-housekeeping.sh's ORGANS table and
# self-test loop, so a fresh-node install actually brings it up.
#
# Fails without RESILIENT-341: reviver is absent from ORGANS and the self-test
# loop, so a fresh-node install never starts post-push-integrity-watch.sh.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TARGET="$REPO_ROOT/scripts/setup/install-node-housekeeping.sh"

PASS=0
FAIL=0
FAILURES=()

pass() { PASS=$((PASS + 1)); printf '  PASS  %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); FAILURES+=("$1: $2"); printf '  FAIL  %s — %s\n' "$1" "$2"; }

[ -f "$TARGET" ] || { echo "FATAL: $TARGET not found"; exit 1; }

# T1: reviver organ entry present, wired to the real daemon script, 60s cadence
if grep -qE '^reviver\|scripts/coord/post-push-integrity-watch\.sh\|60"?$' "$TARGET"; then
    pass "T1: reviver organ entry wired to post-push-integrity-watch.sh @ 60s"
else
    fail "T1" "no 'reviver|scripts/coord/post-push-integrity-watch.sh|60' line in ORGANS table"
fi

# T2: reviver's target script actually exists in the repo (not a dangling reference)
if [ -f "$REPO_ROOT/scripts/coord/post-push-integrity-watch.sh" ]; then
    pass "T2: scripts/coord/post-push-integrity-watch.sh exists"
else
    fail "T2" "post-push-integrity-watch.sh missing from repo"
fi

# T3: reviver is included in the post-install self-test loop (else install can
# silently leave it down with no fresh-node signal)
selftest_line="$(grep -n '^for name in' "$TARGET" | tail -1)"
if printf '%s' "$selftest_line" | grep -q 'reviver'; then
    pass "T3: reviver included in self-test loop"
else
    fail "T3" "self-test loop does not check reviver: $selftest_line"
fi

# T4: syntax check
if bash -n "$TARGET" 2>/dev/null; then
    pass "T4: install-node-housekeeping.sh syntax OK"
else
    fail "T4" "bash -n failed on $TARGET"
fi

echo
echo "=== $PASS passed, $FAIL failed ==="
if [ "$FAIL" -gt 0 ]; then
    printf '%s\n' "${FAILURES[@]}"
    exit 1
fi
exit 0
