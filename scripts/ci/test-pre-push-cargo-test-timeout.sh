#!/usr/bin/env bash
# scripts/ci/test-pre-push-cargo-test-timeout.sh — INFRA-1871
#
# Regression smoke for INFRA-1744 (#2372 merged). Verifies the pre-push
# hook keeps the cargo test invocation wrapped in `timeout`. Today's
# 11-PR fmt cascade traced back to a 30+min hung cargo test from
# sibling-worktree sccache contention — without the timeout, every push
# under load could deadlock the fleet again.
#
# Two cargo-test invocations exist in scripts/git-hooks/pre-push:
#   1. The rerun-script path (cargo-test-with-rerun.sh wrapper)
#   2. The fallback direct cargo-test path
# Both MUST be wrapped in `timeout "${_PREPUSH_TEST_TIMEOUT_S}s"`.

set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HOOK="$REPO_ROOT/scripts/git-hooks/pre-push"
[[ ! -f "$HOOK" ]] && { echo "FAIL: $HOOK missing"; exit 1; }

failures=0
ag() { grep -qE -- "$2" "$1" 2>/dev/null || { echo "FAIL: $3"; failures=$((failures+1)); }; }

ag "$HOOK" "_PREPUSH_TEST_TIMEOUT_S=\"\\\$\\{CHUMP_PREPUSH_TEST_TIMEOUT_S:-" \
    "pre-push exposes CHUMP_PREPUSH_TEST_TIMEOUT_S env knob"

# Count timeout wrappers — must be ≥ 2 (rerun-script + fallback)
n_timeout=$(grep -cE 'timeout "\$\{_PREPUSH_TEST_TIMEOUT_S\}s"' "$HOOK" 2>/dev/null || echo 0)
if [[ "$n_timeout" -lt 2 ]]; then
    echo "FAIL: pre-push must wrap BOTH cargo-test paths in 'timeout \${_PREPUSH_TEST_TIMEOUT_S}s' (found $n_timeout/2 — regression of INFRA-1744 #2372)"
    failures=$((failures+1))
fi

ag "$HOOK" '"kind":"prepush_test_timeout"' \
    "pre-push rc=124 branch emits prepush_test_timeout ambient event"

ag "$HOOK" "INFRA-1744" \
    "pre-push has INFRA-1744 attribution comment (regression marker)"

# Default value pinned at 600s per INFRA-1744 spec
ag "$HOOK" "_PREPUSH_TEST_TIMEOUT_S:-600" \
    "default CHUMP_PREPUSH_TEST_TIMEOUT_S = 600s"

[[ $failures -gt 0 ]] && { echo "FAIL INFRA-1871: $failures (INFRA-1744 regression detected)"; exit 1; }
echo "OK INFRA-1871: pre-push cargo test timeout (INFRA-1744) intact"
