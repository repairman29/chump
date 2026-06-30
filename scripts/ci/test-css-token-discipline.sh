#!/usr/bin/env bash
# test-css-token-discipline.sh — INFRA-1590
#
# Smoke test: run css-token-discipline.sh against clean and dirty fixtures
# and assert the expected exit codes.

set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
LINTER="$REPO_ROOT/scripts/lint/css-token-discipline.sh"
VIOLATION="$REPO_ROOT/tests/fixtures/css-token-violation.html"
CLEAN="$REPO_ROOT/tests/fixtures/css-token-clean.html"

PASS=0
FAIL=0

_assert() {
    local desc="$1"
    local expected="$2"
    shift 2
    local actual=0
    "$@" >/dev/null 2>&1 || actual=$?
    if [[ "$actual" -eq "$expected" ]]; then
        echo "  PASS: $desc"
        (( PASS++ )) || true
    else
        echo "  FAIL: $desc (expected exit $expected, got $actual)"
        (( FAIL++ )) || true
    fi
}

echo "=== css-token-discipline smoke tests ==="

# Linter must exist and be executable
if [[ ! -x "$LINTER" ]]; then
    echo "FAIL: $LINTER is not executable"
    exit 1
fi

# Clean fixture must pass
_assert "clean fixture exits 0" 0 \
    bash "$LINTER" "$CLEAN"

# Violation fixture must fail
_assert "violation fixture exits 1" 1 \
    bash "$LINTER" "$VIOLATION"

# CHUMP_TOKEN_DISCIPLINE_CHECK=0 disables linter even on violations
_assert "CHUMP_TOKEN_DISCIPLINE_CHECK=0 disables linter" 0 \
    env CHUMP_TOKEN_DISCIPLINE_CHECK=0 bash "$LINTER" "$VIOLATION"

# Baseline whitelist: baselined file is skipped even if it has violations.
# Use CSS_DISCIPLINE_BASELINE_OVERRIDE so the linter reads a test baseline.
TMPBL="$(mktemp)"
echo "$(basename "$VIOLATION")" > "$TMPBL"
_assert "baselined file (by basename) is skipped" 0 \
    env CSS_DISCIPLINE_BASELINE_OVERRIDE="$TMPBL" bash "$LINTER" "$VIOLATION"
rm -f "$TMPBL"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
