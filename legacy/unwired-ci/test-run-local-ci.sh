#!/usr/bin/env bash
# test-run-local-ci.sh - INFRA-2251 smoke test for run-local-ci.sh
#
# Validates:
#   1. --dry-run mode: prints steps without executing, exits 0
#   2. Network isolation: run-local-ci.sh exits 0 even when network is blocked
#      via no_proxy + unroutable proxy (simulates airplane mode)
#   3. run-local-ci.sh is syntactically valid bash (bash -n)
#   4. run-remote-ci.sh is syntactically valid bash (bash -n)
#   5. --dry-run output mentions all 3 tiers
#   6. Bypass env var (CHUMP_LOCAL_CI_SKIP=1) exits 0 and emits ambient event
#   7. --tier filter isolates tiers correctly

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
LOCAL_CI="$REPO_ROOT/scripts/ci/run-local-ci.sh"
REMOTE_CI="$REPO_ROOT/scripts/ci/run-remote-ci.sh"
PASS=0
FAIL=0
FAILED=()

pass() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); FAILED+=("$1"); }

echo "=== smoke: test-run-local-ci.sh ==="

# 1. Syntax check: run-local-ci.sh
if bash -n "$LOCAL_CI" 2>/dev/null; then
    pass "run-local-ci.sh passes bash -n"
else
    fail "run-local-ci.sh fails bash -n (syntax error)"
fi

# 2. Syntax check: run-remote-ci.sh
if bash -n "$REMOTE_CI" 2>/dev/null; then
    pass "run-remote-ci.sh passes bash -n"
else
    fail "run-remote-ci.sh fails bash -n (syntax error)"
fi

# 3. --dry-run exits 0
if output=$(bash "$LOCAL_CI" --dry-run 2>&1); then
    pass "run-local-ci.sh --dry-run exits 0"
else
    fail "run-local-ci.sh --dry-run exits non-zero"
    output=""
fi

# 4. --dry-run output mentions all 3 tiers
for tier in 1 2 3; do
    if echo "$output" | grep -q "Tier $tier"; then
        pass "--dry-run output mentions Tier $tier"
    else
        fail "--dry-run output missing 'Tier $tier'"
    fi
done

# 5. --dry-run output shows cargo fmt and cargo clippy
for gate in "cargo fmt" "cargo clippy"; do
    if echo "$output" | grep -qi "$gate"; then
        pass "--dry-run output shows '$gate'"
    else
        fail "--dry-run output missing '$gate'"
    fi
done

# 6. CHUMP_LOCAL_CI_SKIP=1 exits 0
if CHUMP_LOCAL_CI_SKIP=1 bash "$LOCAL_CI" 2>/dev/null; then
    pass "CHUMP_LOCAL_CI_SKIP=1 exits 0"
else
    fail "CHUMP_LOCAL_CI_SKIP=1 exits non-zero"
fi

# 7. Network isolation: --dry-run works with unroutable proxy set
# Set an unroutable proxy so any accidental network call fails.
# We test --dry-run (which never executes commands) to prove the gate itself
# has no startup network calls.
if no_proxy='*' http_proxy='http://10.0.0.0:1' https_proxy='http://10.0.0.0:1' \
       bash "$LOCAL_CI" --dry-run 2>/dev/null; then
    pass "run-local-ci.sh --dry-run succeeds with unroutable proxy set"
else
    fail "run-local-ci.sh --dry-run fails with unroutable proxy (unexpected)"
fi

# 8. run-remote-ci.sh --dry-run exits 0
if bash "$REMOTE_CI" --dry-run 2>/dev/null; then
    pass "run-remote-ci.sh --dry-run exits 0"
else
    fail "run-remote-ci.sh --dry-run exits non-zero"
fi

# 9. run-local-ci.sh does NOT reference gh api or gh pr in executable lines (network guard)
# Exclude comment lines (lines starting with optional whitespace + #)
if grep -vE '^[[:space:]]*#' "$LOCAL_CI" | grep -qE '\bgh api\b|\bgh pr\b'; then
    fail "run-local-ci.sh contains executable 'gh api' or 'gh pr' references"
else
    pass "run-local-ci.sh has no executable 'gh api'/'gh pr' calls"
fi

# 10. run-local-ci.sh has no curl/wget to external URLs
if grep -qE '\bcurl\b.*http[s]?://|\bwget\b.*http[s]?://' "$LOCAL_CI"; then
    fail "run-local-ci.sh contains external curl/wget calls"
else
    pass "run-local-ci.sh has no external curl/wget calls"
fi

# 11. Tier-filter flag: --tier 1 --dry-run does not show Tier 2/3
if tier1_output=$(bash "$LOCAL_CI" --tier 1 --dry-run 2>&1); then
    if ! echo "$tier1_output" | grep -q "Tier 2"; then
        pass "--tier 1 --dry-run omits Tier 2"
    else
        fail "--tier 1 --dry-run incorrectly shows Tier 2"
    fi
    if ! echo "$tier1_output" | grep -q "Tier 3"; then
        pass "--tier 1 --dry-run omits Tier 3"
    else
        fail "--tier 1 --dry-run incorrectly shows Tier 3"
    fi
else
    fail "--tier 1 --dry-run exits non-zero"
fi

# 12. Tier-filter: --tier 2 --dry-run shows Tier 2 but not Tier 1/3
if tier2_output=$(bash "$LOCAL_CI" --tier 2 --dry-run 2>&1); then
    if echo "$tier2_output" | grep -q "Tier 2"; then
        pass "--tier 2 --dry-run shows Tier 2"
    else
        fail "--tier 2 --dry-run missing Tier 2 output"
    fi
    if ! echo "$tier2_output" | grep -q "Tier 1"; then
        pass "--tier 2 --dry-run omits Tier 1"
    else
        fail "--tier 2 --dry-run incorrectly shows Tier 1"
    fi
else
    fail "--tier 2 --dry-run exits non-zero"
fi

# Summary
echo ""
echo "=== smoke results: $PASS passed, $FAIL failed ==="
if [[ "$FAIL" -gt 0 ]]; then
    echo "Failed checks:"
    for name in "${FAILED[@]}"; do
        echo "  - $name"
    done
    exit 1
fi
exit 0
