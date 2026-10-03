#!/usr/bin/env bash
# test-bypass-line-in-failed-jobs.sh — INFRA-4537 (INFRA-1861 slice)
#
# Self-test for scripts/ci/check-bypass-line-in-failed-jobs.sh. Runs it
# against fixture job logs (no network / gh calls) and asserts:
#   - a failed lane whose log has NO bypass line is flagged
#   - a failed lane whose log DOES have a bypass line passes
#   - a lane that did not fail (result=success) is never inspected, even
#     if its log would fail the pattern check
#   - zero failed lanes -> clean pass (nothing to check)
#
# Exit: 0 = clean, 1 = the audit logic failed to behave as expected.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CHECK_SCRIPT="$SCRIPT_DIR/check-bypass-line-in-failed-jobs.sh"

pass() { printf '[PASS] %s\n' "$*"; }
fail() { printf '[FAIL] %s\n' "$*" >&2; }

FIXTURE_DIR="$(mktemp -d -t bypass-line-failed-jobs-selftest.XXXXXX)"
trap 'rm -rf "$FIXTURE_DIR"' EXIT

cat > "$FIXTURE_DIR/without-bypass.log" <<'EOF'
Running check...
[FAIL] synthetic violation for self-test
Error: process completed with exit code 1.
EOF

cat > "$FIXTURE_DIR/with-bypass.log" <<'EOF'
Running check...
[FAIL] synthetic violation for self-test
How to bypass cleanly: this is a fixture, there is nothing to bypass
Error: process completed with exit code 1.
EOF

SELFTEST_FAILED=0

# Case 1: a failed lane with no bypass line must be flagged (exit 1).
if CHUMP_FAILED_JOB_LOG_FIXTURE_DIR="$FIXTURE_DIR" bash "$CHECK_SCRIPT" \
    --lane "without-bypass=failure" >/tmp/bypass-case1.out 2>&1; then
    fail "case 1: expected nonzero exit for a failed lane with no bypass line"
    cat /tmp/bypass-case1.out
    SELFTEST_FAILED=1
else
    pass "case 1: correctly flags a failed lane with no bypass line"
fi

# Case 2: a failed lane WITH a bypass line must pass (exit 0).
if CHUMP_FAILED_JOB_LOG_FIXTURE_DIR="$FIXTURE_DIR" bash "$CHECK_SCRIPT" \
    --lane "with-bypass=failure" >/tmp/bypass-case2.out 2>&1; then
    pass "case 2: correctly clears a failed lane that has a bypass line"
else
    fail "case 2: expected zero exit for a failed lane with a bypass line"
    cat /tmp/bypass-case2.out
    SELFTEST_FAILED=1
fi

# Case 3: a lane that did NOT fail is never inspected, even though its log
# (if it were checked) would fail the pattern match.
if CHUMP_FAILED_JOB_LOG_FIXTURE_DIR="$FIXTURE_DIR" bash "$CHECK_SCRIPT" \
    --lane "without-bypass=success" >/tmp/bypass-case3.out 2>&1; then
    pass "case 3: a successful lane is skipped regardless of its log content"
else
    fail "case 3: expected zero exit — successful lanes must not be inspected"
    cat /tmp/bypass-case3.out
    SELFTEST_FAILED=1
fi

# Case 4: zero failed lanes -> clean pass.
if CHUMP_FAILED_JOB_LOG_FIXTURE_DIR="$FIXTURE_DIR" bash "$CHECK_SCRIPT" \
    --lane "with-bypass=success" --lane "without-bypass=skipped" \
    >/tmp/bypass-case4.out 2>&1; then
    pass "case 4: no failed lanes -> clean pass"
else
    fail "case 4: expected zero exit when nothing failed"
    cat /tmp/bypass-case4.out
    SELFTEST_FAILED=1
fi

echo ""
if [[ "$SELFTEST_FAILED" -eq 0 ]]; then
    echo "INFRA-4537: check-bypass-line-in-failed-jobs.sh self-test passed."
    exit 0
else
    fail "INFRA-4537: self-test has no bypass — it is asserting the audit mechanism itself works; fix scripts/ci/check-bypass-line-in-failed-jobs.sh"
    fail "How to bypass cleanly: this self-test has no bypass; it exists to prove the dynamic bypass-line audit works correctly."
    exit 1
fi
