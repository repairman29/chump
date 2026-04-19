#!/usr/bin/env bash
# Smoke test for claude-retry.sh
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RETRY="$SCRIPT_DIR/claude-retry.sh"
FIX="$SCRIPT_DIR/test-fixtures"

PASS=0; FAIL=0
check() { if [ "$1" = "$2" ]; then echo "  PASS: $3"; PASS=$((PASS+1)); else echo "  FAIL: $3 (got $1, want $2)"; FAIL=$((FAIL+1)); fi; }

echo "=== Test 1: success on first attempt ==="
CHUMP_CLAUDE_BIN_OVERRIDE="$FIX/fake-claude-success.sh" \
  CHUMP_CLAUDE_RETRY_MAX=3 \
  "$RETRY" hello >/dev/null 2>&1
check "$?" "0" "exit 0 on success"

echo "=== Test 2: 5xx on attempt 1 → success on retry ==="
rm -f /tmp/fake-claude-counter
CHUMP_CLAUDE_BIN_OVERRIDE="$FIX/fake-claude-5xx-then-success.sh" \
  CHUMP_CLAUDE_RETRY_MAX=3 \
  CHUMP_CLAUDE_RETRY_BACKOFFS="1 1 1" \
  "$RETRY" hello >/dev/null 2>&1
check "$?" "0" "exit 0 after retry recovery"

echo "=== Test 3: always 5xx → exhaust retries → exit non-zero ==="
CHUMP_CLAUDE_BIN_OVERRIDE="$FIX/fake-claude-always-5xx.sh" \
  CHUMP_CLAUDE_RETRY_MAX=2 \
  CHUMP_CLAUDE_RETRY_BACKOFFS="1 1" \
  "$RETRY" hello >/dev/null 2>&1
check "$?" "1" "exit non-zero after retries exhausted"

echo "=== Test 4: 401 (non-retryable) → exit immediately ==="
START=$(date +%s)
CHUMP_CLAUDE_BIN_OVERRIDE="$FIX/fake-claude-non-retryable.sh" \
  CHUMP_CLAUDE_RETRY_MAX=3 \
  CHUMP_CLAUDE_RETRY_BACKOFFS="60 60 60" \
  "$RETRY" hello >/dev/null 2>&1
EXIT=$?
END=$(date +%s)
ELAPSED=$((END-START))
check "$EXIT" "1" "exit non-zero on 401"
[ "$ELAPSED" -lt "5" ] && echo "  PASS: 401 fail-fast (took ${ELAPSED}s, no retry)" || echo "  FAIL: 401 should have failed fast (took ${ELAPSED}s)"

echo ""
echo "=== Summary: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq "0" ] && exit 0 || exit 1
