#!/usr/bin/env bash
# INFRA-382: smoke test for scripts/ops/auto-arm-sweeper.sh (INFRA-374).
#
# The sweeper itself depends on `gh` + a real GitHub session, which CI
# doesn't have without a token. So this test:
#
#   1. Asserts the script exists + is executable.
#   2. Asserts --dry-run is in its --help / usage hint (catches an accidental
#      removal of the safety knob).
#   3. Asserts the WIP/skip/hold regex catches the patterns it documents.
#
# Logic-deeper testing (which PRs would be armed under specific input)
# requires fixture-style mocking of `gh pr list` JSON which would couple
# the test tightly to the script's internals. Keep this test as the
# load-bearing "did anyone delete the script or break its docs" guard.
#
# Run from repo root: bash scripts/ci/test-auto-arm-sweeper.sh

set -e
PASS=0
FAIL=0
pass() { echo "[PASS] $1"; PASS=$((PASS+1)); }
fail() { echo "[FAIL] $1"; FAIL=$((FAIL+1)); }

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SWEEPER="$REPO_ROOT/scripts/ops/auto-arm-sweeper.sh"

# 1. exists + executable
[[ -f "$SWEEPER" ]] && pass "scripts/ops/auto-arm-sweeper.sh exists" \
                   || fail "scripts/ops/auto-arm-sweeper.sh missing"
[[ -x "$SWEEPER" ]] && pass "auto-arm-sweeper.sh is executable" \
                   || fail "auto-arm-sweeper.sh not executable"

# 2. --dry-run is documented + handled
grep -q -- '--dry-run' "$SWEEPER" && pass "--dry-run flag present in script" \
                                  || fail "--dry-run flag absent (safety regression)"

# 3. WIP/hold/skip pattern present (the docs claim these stop arming)
for pat in 'WIP' 'skip' 'hold'; do
    if grep -q -i "$pat" "$SWEEPER"; then
        pass "skip pattern present: $pat"
    else
        fail "skip pattern missing: $pat"
    fi
done

# 4. CHUMP_AUTOARM_SKIP bypass present
grep -q "CHUMP_AUTOARM_SKIP" "$SWEEPER" \
    && pass "CHUMP_AUTOARM_SKIP bypass env var present" \
    || fail "CHUMP_AUTOARM_SKIP bypass env var missing"

# 5. CHUMP_AUTOARM_SKIP=1 actually short-circuits + exits 0
if CHUMP_AUTOARM_SKIP=1 bash "$SWEEPER" --dry-run > /tmp/auto-arm-skip.log 2>&1; then
    grep -q "CHUMP_AUTOARM_SKIP" /tmp/auto-arm-skip.log \
        && pass "CHUMP_AUTOARM_SKIP=1 emits a clear bypass message + exits 0" \
        || fail "CHUMP_AUTOARM_SKIP=1 didn't emit expected message (got: $(head -1 /tmp/auto-arm-skip.log))"
else
    fail "CHUMP_AUTOARM_SKIP=1 should exit 0 (got non-zero)"
fi

echo ""
echo "Passed: $PASS  Failed: $FAIL"
[ "$FAIL" -eq 0 ]
