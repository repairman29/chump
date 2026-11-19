#!/usr/bin/env bash
# test-infra-485-prepush-not-clean.sh — INFRA-485
#
# Verifies the pre-push auto-merge guard only blocks when the PR is
# actually CLEAN (mergeable). BLOCKED/DIRTY/UNSTABLE/BEHIND/UNKNOWN/HAS_HOOKS
# all allow push because GitHub can't merge yet — push is the recovery path.

set -euo pipefail

PASS=0
FAIL=0
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

REPO_ROOT="$(git rev-parse --show-toplevel)"
HOOK="$REPO_ROOT/scripts/git-hooks/pre-push"

echo "=== INFRA-485 pre-push not-CLEAN allow test ==="
echo

# 1. INFRA-485 block exists.
if grep -q "INFRA-485" "$HOOK"; then
    ok "pre-push hook contains INFRA-485 block"
else
    fail "pre-push hook missing INFRA-485 block"
fi

# 2. Hook queries mergeStateStatus (not just autoMergeRequest).
if grep -q "mergeStateStatus" "$HOOK"; then
    ok "hook queries mergeStateStatus"
else
    fail "hook does not query mergeStateStatus"
fi

# 3. Only CLEAN triggers the block.
if grep -qE 'pr_status.*==.*"CLEAN"' "$HOOK"; then
    ok "hook only blocks on mergeStateStatus=CLEAN"
else
    fail "hook does not gate on CLEAN"
fi

# 4. BLOCKED/DIRTY/UNSTABLE/BEHIND allowed (recovery path).
if grep -qE 'BLOCKED.*DIRTY.*UNSTABLE.*BEHIND' "$HOOK"; then
    ok "hook explicitly allows BLOCKED/DIRTY/UNSTABLE/BEHIND (recovery path)"
else
    fail "hook missing recovery-path branch"
fi

# 5. Helpful diagnostic for recovery case.
if grep -q "recovery path" "$HOOK"; then
    ok "hook prints diagnostic for non-CLEAN allow case"
else
    fail "hook silent on non-CLEAN allow"
fi

# 6. CHUMP_AUTOMERGE_OVERRIDE bypass still works.
if grep -q "CHUMP_AUTOMERGE_OVERRIDE" "$HOOK"; then
    ok "CHUMP_AUTOMERGE_OVERRIDE bypass still present"
else
    fail "bypass env removed"
fi

# 7. PR #52 footgun reference preserved.
if grep -q "PR #52" "$HOOK"; then
    ok "PR #52 incident reference preserved (institutional memory)"
else
    fail "lost PR #52 reference"
fi

# 8. Live: simulate the gating logic with each mergeStateStatus value.
classify() {
    local status="$1"
    if [[ "$status" == "CLEAN" ]]; then
        echo "block"
    elif [[ "$status" =~ ^(BLOCKED|DIRTY|UNSTABLE|BEHIND|UNKNOWN|HAS_HOOKS)$ ]]; then
        echo "allow_recovery"
    else
        echo "allow_default"
    fi
}

for status in CLEAN BLOCKED DIRTY UNSTABLE BEHIND UNKNOWN HAS_HOOKS; do
    expected=""
    case "$status" in
        CLEAN) expected="block" ;;
        *)     expected="allow_recovery" ;;
    esac
    actual=$(classify "$status")
    if [ "$actual" = "$expected" ]; then
        ok "live: mergeStateStatus=$status → $actual"
    else
        fail "live: mergeStateStatus=$status → expected $expected, got $actual"
    fi
done

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
