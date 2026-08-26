#!/usr/bin/env bash
# test-chump-startup-timeout.sh — INFRA-3784 (INFRA-1809 slice)
#
# Verifies the startup wallclock budget enforced at main.rs entry:
#  1. CHUMP_STARTUP_TIMEOUT_MS=1 forces `chump --version` to hit the timeout
#     path and exit with code 4.
#  2. The timeout diagnostic dump lands on stderr.
#  3. A generous default budget still lets `chump --version` succeed normally.
#
# Run from repo root: bash scripts/ci/test-chump-startup-timeout.sh

set -u
REPO_ROOT=$(git rev-parse --show-toplevel)
cd "$REPO_ROOT"

PASS=0
FAIL=0
pass() { echo "[PASS] $1"; PASS=$((PASS+1)); }
fail() { echo "[FAIL] $1"; FAIL=$((FAIL+1)); }

BIN=""
for candidate in target/debug/chump target/release/chump; do
    if [ -x "$candidate" ]; then
        BIN="$candidate"
        break
    fi
done

if [ -z "$BIN" ]; then
    echo "SKIP: no built chump binary found (target/debug|release/chump) — build before running this test"
    exit 0
fi

STDERR_FILE=$(mktemp)
trap 'rm -f "$STDERR_FILE"' EXIT

CHUMP_STARTUP_TIMEOUT_MS=1 "$BIN" --version >/dev/null 2>"$STDERR_FILE"
rc=$?

if [ "$rc" -eq 4 ]; then
    pass "CHUMP_STARTUP_TIMEOUT_MS=1 chump --version exits 4"
else
    fail "CHUMP_STARTUP_TIMEOUT_MS=1 chump --version exited $rc, expected 4"
fi

if grep -q "chump_startup_timeout" "$STDERR_FILE"; then
    pass "timeout diagnostic dump present on stderr"
else
    fail "no chump_startup_timeout diagnostic found on stderr"
fi

"$BIN" --version >/dev/null 2>/dev/null
rc=$?
if [ "$rc" -eq 0 ]; then
    pass "default budget: chump --version still succeeds"
else
    fail "default budget: chump --version exited $rc, expected 0"
fi

echo "---"
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
