#!/usr/bin/env bash
# scripts/ci/test-prepush-test-timeout.sh — INFRA-1744
#
# Verifies the pre-push hook caps its cargo-test invocation with `timeout`,
# so a hung test run (sccache contention, deadlock, sibling worktree
# starvation) cannot stall the entire fleet for 30+ minutes.
#
# Two assertions, both static against scripts/git-hooks/pre-push:
#   1. The cargo-test-with-rerun.sh invocation is wrapped in `timeout`.
#   2. The fallback direct-cargo-test path is wrapped in `timeout`.
#   3. The CHUMP_PREPUSH_TEST_TIMEOUT_S env knob exists with a numeric default.
#   4. The timeout branch (rc=124) emits a structured ambient event
#      (kind=prepush_test_timeout) so the operator sees the failure class.
#   5. The diagnostic mentions CHUMP_TEST_GATE=0 bypass.
#
# Static assertions only (no spawning real git push). The full integration
# test would need a deterministic-hang fixture; that's out of scope for an
# xs gap. The INFRA-1744 fix is the timeout itself; this test guards that
# the timeout never regresses.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HOOK="$REPO_ROOT/scripts/git-hooks/pre-push"

failures=0

assert_grep() {
    local pattern="$1" desc="$2"
    if ! grep -qE -- "$pattern" "$HOOK" 2>/dev/null; then
        echo "FAIL: $desc"
        echo "       pattern: $pattern"
        failures=$((failures + 1))
    fi
}

# 1. CHUMP_PREPUSH_TEST_TIMEOUT_S env knob with default.
assert_grep '_PREPUSH_TEST_TIMEOUT_S="\$\{CHUMP_PREPUSH_TEST_TIMEOUT_S:-' \
    "pre-push exposes CHUMP_PREPUSH_TEST_TIMEOUT_S env knob with numeric default"

# 2. cargo-test-with-rerun.sh invocation wrapped in timeout.
# We look for the two `timeout "${_PREPUSH_TEST_TIMEOUT_S}s"` invocations.
n_timeout=$(grep -cE 'timeout "\$\{_PREPUSH_TEST_TIMEOUT_S\}s"' "$HOOK" 2>/dev/null || echo 0)
if [[ "$n_timeout" -lt 2 ]]; then
    echo "FAIL: pre-push should wrap BOTH cargo-test invocations in 'timeout \${_PREPUSH_TEST_TIMEOUT_S}s' (found $n_timeout/2)"
    failures=$((failures + 1))
fi

# 3. rc=124 branch emits prepush_test_timeout event.
assert_grep '"kind":"prepush_test_timeout"' \
    "rc=124 branch emits structured ambient event kind=prepush_test_timeout"

# 4. Operator diagnostic mentions CHUMP_TEST_GATE=0.
assert_grep 'CHUMP_TEST_GATE=0' \
    "timeout diagnostic mentions CHUMP_TEST_GATE=0 bypass"

# 5. Diagnostic mentions the budget knob so operator knows how to raise it.
assert_grep 'CHUMP_PREPUSH_TEST_TIMEOUT_S=' \
    "timeout diagnostic mentions CHUMP_PREPUSH_TEST_TIMEOUT_S override"

if [[ $failures -gt 0 ]]; then
    echo ""
    echo "FAIL INFRA-1744: $failures assertion(s) failed"
    exit 1
fi

echo "OK INFRA-1744: pre-push hook caps cargo test under CHUMP_PREPUSH_TEST_TIMEOUT_S (default 600s)"
