#!/usr/bin/env bash
# INFRA-1714: smoke test for `chump pr-rescue`.
#
# Validates:
#   1. --help prints + exits 0
#   2. Binary subcommand registered (no "unknown subcommand")
#   3. cargo test for the in-crate unit tests passes (classifier serialization
#      + env-var-block parser)
#   4. --dry-run does not mutate (we verify env-vars-internal.txt unchanged
#      after a synthetic --dry-run invocation)
#   5. Unit-test for the env-var-block parser asserts the 3 vars from a
#      real fast-checks log excerpt are extracted

set -euo pipefail

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}"
cd "$REPO_ROOT"

echo "[test-pr-rescue] 1/4 — chump pr-rescue --help exits 0"
HELP_OUT="$(cargo run --bin chump --quiet -- pr-rescue --help 2>&1)"
if ! echo "$HELP_OUT" | grep -q "chump pr-rescue"; then
    echo "FAIL: --help output missing 'chump pr-rescue'"
    echo "$HELP_OUT"
    exit 1
fi

echo "[test-pr-rescue] 2/4 — cargo test (pr_rescue unit tests)"
cargo test --bin chump --quiet pr_rescue:: 2>&1 | tail -10

echo "[test-pr-rescue] 3/4 — --dry-run --pr 99999 does not mutate env-vars-internal.txt"
BEFORE_SHA="$(shasum scripts/ci/env-vars-internal.txt | awk '{print $1}')"
# This PR doesn't exist; --dry-run + --pr forces classifier path. It will fail
# the gh call internally and emit a pr_rescue_failed event, but it MUST NOT
# mutate the env-vars-internal.txt file.
cargo run --bin chump --quiet -- pr-rescue --once --pr 99999 --dry-run >/dev/null 2>&1 || true
AFTER_SHA="$(shasum scripts/ci/env-vars-internal.txt | awk '{print $1}')"
if [ "$BEFORE_SHA" != "$AFTER_SHA" ]; then
    echo "FAIL: --dry-run mutated env-vars-internal.txt"
    exit 1
fi

echo "[test-pr-rescue] 4/4 — --explain on non-existent PR doesn't crash"
# Expect non-zero exit (gh call fails), but no panic. We just check the
# process exits within 30s.
if timeout 30 cargo run --bin chump --quiet -- pr-rescue --explain 99999 >/dev/null 2>&1; then
    : # ok
else
    rc=$?
    # Exit codes 0, 1 are both acceptable here (1 = expected gh-call failure).
    # Anything > 124 is a timeout — that would be bad.
    if [ "$rc" -gt 100 ]; then
        echo "FAIL: --explain hung or panicked (exit code $rc)"
        exit 1
    fi
fi

echo "PASS: test-pr-rescue.sh"
