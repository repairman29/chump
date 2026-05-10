#!/usr/bin/env bash
# CREDIBLE-017: Validate all CLI commands use standard exit codes.
set -euo pipefail

BINARY="${1:-target/debug/chump}"
PASS=0
FAIL=0

pass() { PASS=$((PASS+1)); }
fail() { FAIL=$((FAIL+1)); echo "FAIL: $*"; }

check_exit() {
    local desc="$1" expected="$2" actual="$3"
    if [ "$actual" = "$expected" ]; then
        pass
    else
        fail "$desc: expected exit $expected, got exit $actual"
    fi
}

# ── 1. Static audit: source must never use exit codes outside {0,1,2} ──
echo "=== Static audit: source exit codes ==="
SRC_DIR="$(cd "$(dirname "$0")/../../src" && pwd)"
BAD_CODES=$(rg -o 'process::exit\((\d+)\)' "$SRC_DIR" --replace '$1' | awk '$1 >= 3' || true)
if [ -n "$BAD_CODES" ]; then
    fail "non-standard exit codes found in src/"
    echo "$BAD_CODES"
else
    pass
fi

# ── 2. Binary must exist ──
echo "=== Binary smoke tests ==="
if [ ! -x "$BINARY" ]; then
    # Try building
    cargo build --bin chump -q 2>/dev/null || true
fi
if [ ! -x "$BINARY" ]; then
    fail "binary not found at $BINARY, skipping runtime tests"
    echo "---"
    echo "Result: $PASS passed, $FAIL failed"
    exit $(( FAIL > 0 ? 1 : 0 ))
fi

CHUMP="$BINARY"

# 2a. no args → exit 2 (usage error)
set +e
"$CHUMP" >/dev/null 2>&1
RC=$?
set -e
check_exit "chump (no args)" 2 $RC

# 2b. unknown subcommand → exit 2
set +e
"$CHUMP" nonexistent-subcommand 2>/dev/null
RC=$?
set -e
check_exit "chump nonexistent-subcommand" 2 $RC

# 2c. gap show (no args) → exit 2
set +e
"$CHUMP" gap show 2>/dev/null
RC=$?
set -e
check_exit "chump gap show (no args)" 2 $RC

# 2d. gap show nonexistent → exit 1
set +e
"$CHUMP" gap show CREDIBLE-NONEXIST 2>/dev/null
RC=$?
set -e
check_exit "chump gap show CREDIBLE-NONEXIST" 1 $RC

# 2e. fleet (no subcommand) → exit 2
set +e
"$CHUMP" fleet 2>/dev/null
RC=$?
set -e
check_exit "chump fleet (no args)" 2 $RC

# 2f. gap list → exit 0 (success)
set +e
"$CHUMP" gap list 2>/dev/null
RC=$?
set -e
check_exit "chump gap list" 0 $RC

# 2g. fleet help → exit 2
set +e
"$CHUMP" fleet help 2>/dev/null
RC=$?
set -e
check_exit "chump fleet help" 2 $RC

# 2h. init --help → exit 2
set +e
"$CHUMP" init --help 2>/dev/null
RC=$?
set -e
check_exit "chump init --help" 2 $RC

echo "---"
echo "Result: $PASS passed, $FAIL failed"
exit $(( FAIL > 0 ? 1 : 0 ))
