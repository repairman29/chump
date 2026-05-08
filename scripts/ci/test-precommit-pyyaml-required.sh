#!/usr/bin/env bash
# CREDIBLE-003: verify pre-commit fails loudly if PyYAML is not installed.
# When gap YAML validation is attempted but PyYAML is unavailable,
# the hook must fail with a clear, actionable error message —
# not silently skip the guard.

set -euo pipefail
PASS=0; FAIL=0
pass() { echo "[PASS] $1"; PASS=$((PASS+1)); }
fail() { echo "[FAIL] $1"; FAIL=$((FAIL+1)); }

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HOOK="$REPO_ROOT/scripts/git-hooks/pre-commit"

[[ -f "$HOOK" ]] || { fail "pre-commit hook missing"; exit 1; }
pass "pre-commit hook present"

# Test 1: Hook has error handling for missing PyYAML
grep -q "PyYAML not installed" "$HOOK" && pass "PyYAML error message present" || fail "PyYAML error message missing"

# Test 2: Hook has actionable install instructions
if grep -q "pip install pyyaml" "$HOOK" && grep -q "brew install" "$HOOK"; then
    pass "error message has both pip and brew install hints"
else
    fail "error message lacks proper install instructions"
fi

# Test 3: Hook exits with non-zero on ImportError
if grep -A 8 "except ImportError" "$HOOK" | grep -q "sys.exit(1)"; then
    pass "hook exits non-zero on PyYAML ImportError"
else
    fail "hook doesn't exit non-zero on ImportError"
fi

# Test 4: Verify the old silent skip (sys.exit(0)) is gone
if grep -A 2 "except ImportError" "$HOOK" | grep -q "sys.exit(0)"; then
    fail "old silent skip still present (sys.exit(0))"
else
    pass "old silent skip removed"
fi

echo ""
echo "====== Test Summary ======"
echo "Passed: $PASS"
echo "Failed: $FAIL"
[ $FAIL -eq 0 ] && exit 0 || exit 1
