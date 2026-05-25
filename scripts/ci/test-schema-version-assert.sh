#!/usr/bin/env bash
# scripts/ci/test-schema-version-assert.sh — INFRA-1978
#
# Tests for scripts/dispatch/lib/assert-schema.sh.
#
# Verifies:
#   1. assert_schema with matching version passes (exits 0, no stderr)
#   2. assert_schema with mismatched version fails with clear stderr message
#   3. assert_schema with missing schema_version field fails cleanly
#   4. assert_schema with empty JSON string fails cleanly
#   5. Helper is idempotent (safe to source twice)

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
HELPER="$REPO_ROOT/scripts/dispatch/lib/assert-schema.sh"

PASS=0
FAIL=0
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

echo "=== INFRA-1978 assert-schema.sh unit tests ==="
echo

# Verify the helper file exists
if [[ ! -f "$HELPER" ]]; then
    echo "FAIL: $HELPER not found — cannot run tests"
    exit 1
fi

# Source it
# shellcheck source=../dispatch/lib/assert-schema.sh
source "$HELPER"

# ── Test 1: matching version passes ──────────────────────────────────────────
echo "Test 1: assert_schema with matching version exits 0"
JSON_MATCH='{"schema_version":1,"kind":"fleet_health","score":88}'
if assert_schema "$JSON_MATCH" 1 2>/dev/null; then
    ok "assert_schema passes when schema_version matches expected"
else
    fail "assert_schema should pass with matching version=1 (exit was non-zero)"
fi

# ── Test 2: mismatched version fails with clear stderr ────────────────────────
echo "Test 2: assert_schema with mismatched version exits non-zero + clear stderr"
JSON_MISMATCH='{"schema_version":2,"kind":"fleet_health","score":88}'
STDERR_OUT=$(assert_schema "$JSON_MISMATCH" 1 2>&1 >/dev/null || true)
ASSERT_EXIT=0
assert_schema "$JSON_MISMATCH" 1 >/dev/null 2>/dev/null && ASSERT_EXIT=0 || ASSERT_EXIT=$?
if [[ "$ASSERT_EXIT" -ne 0 ]]; then
    ok "assert_schema exits non-zero on version mismatch (got=$ASSERT_EXIT)"
else
    fail "assert_schema should exit non-zero when got=2 expected=1"
fi
if echo "$STDERR_OUT" | grep -q "schema mismatch"; then
    ok "stderr contains 'schema mismatch' message"
else
    fail "stderr should contain 'schema mismatch'; got: ${STDERR_OUT:0:200}"
fi
if echo "$STDERR_OUT" | grep -q "got=2"; then
    ok "stderr shows actual version (got=2)"
else
    fail "stderr should show actual version got=2; got: ${STDERR_OUT:0:200}"
fi
if echo "$STDERR_OUT" | grep -q "expected=1"; then
    ok "stderr shows expected version (expected=1)"
else
    fail "stderr should show expected=1; got: ${STDERR_OUT:0:200}"
fi
if echo "$STDERR_OUT" | grep -q "consumer needs update"; then
    ok "stderr contains 'consumer needs update' guidance"
else
    fail "stderr should contain 'consumer needs update'; got: ${STDERR_OUT:0:200}"
fi

# ── Test 3: missing schema_version field fails cleanly ───────────────────────
echo "Test 3: assert_schema with missing schema_version field exits non-zero"
JSON_NO_VERSION='{"kind":"fleet_health","score":88}'
STDERR_MISSING=$(assert_schema "$JSON_NO_VERSION" 1 2>&1 >/dev/null || true)
MISSING_EXIT=0
assert_schema "$JSON_NO_VERSION" 1 >/dev/null 2>/dev/null && MISSING_EXIT=0 || MISSING_EXIT=$?
if [[ "$MISSING_EXIT" -ne 0 ]]; then
    ok "assert_schema exits non-zero when schema_version field is absent"
else
    fail "assert_schema should fail when schema_version is missing"
fi
if echo "$STDERR_MISSING" | grep -q "schema_version field missing\|schema_version.*missing\|missing"; then
    ok "stderr explains the missing field"
else
    fail "stderr should explain missing field; got: ${STDERR_MISSING:0:200}"
fi

# ── Test 4: empty JSON string fails cleanly ───────────────────────────────────
echo "Test 4: assert_schema with empty string exits non-zero"
EMPTY_EXIT=0
assert_schema "" 1 >/dev/null 2>/dev/null && EMPTY_EXIT=0 || EMPTY_EXIT=$?
if [[ "$EMPTY_EXIT" -ne 0 ]]; then
    ok "assert_schema exits non-zero on empty input"
else
    fail "assert_schema should fail on empty JSON string"
fi

# ── Test 5: idempotent — safe to source twice ─────────────────────────────────
echo "Test 5: sourcing assert-schema.sh twice is idempotent"
source "$HELPER"
# Function should still work after double-source
if assert_schema "$JSON_MATCH" 1 2>/dev/null; then
    ok "assert_schema works correctly after double-source"
else
    fail "double-source broke assert_schema"
fi

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
if [[ "$FAIL" -gt 0 ]]; then
    echo "FAIL: $FAIL test(s) did not pass"
    exit 1
fi
echo "PASS: all assert-schema tests passed"
exit 0
