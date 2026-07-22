#!/usr/bin/env bash
# scripts/ci/test-chump-brain-cli.sh — INFRA-1773
#
# Smoke test for `chump brain stats` / `chump brain query <term>` — the
# first incremental slice of the unified query surface over memory_db +
# reflection_db + routing_outcomes.
#
# Asserts kind=chump_brain_cli_run is emitted on every exit path with the
# expected outcome/failure_class:
#   1. `brain stats`              -> outcome=success, failure_class=none
#   2. `brain query <term>`       -> outcome=success, failure_class=none
#   3. `brain query` (no term)    -> outcome=error,   failure_class=permanent
#   4. `brain bogus-sub`          -> outcome=error,   failure_class=permanent
#
# Runnable standalone:
#   scripts/ci/test-chump-brain-cli.sh
#
# Exit codes:
#   0 = all tests pass (or SKIP if binary not built)
#   1 = test failure

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd -P)"

fail() {
    echo "[test-chump-brain-cli] FAIL: $*" >&2
    exit 1
}

pass() {
    echo "[test-chump-brain-cli] PASS: $*"
}

CHUMP_BIN="${CHUMP_BIN:-}"
if [[ -z "$CHUMP_BIN" ]]; then
    if [[ -f "$REPO_ROOT/target/debug/chump" ]]; then
        CHUMP_BIN="$REPO_ROOT/target/debug/chump"
    elif command -v chump &>/dev/null; then
        CHUMP_BIN="$(command -v chump)"
    else
        echo "SKIP: chump binary not found (set CHUMP_BIN or run cargo build first)" >&2
        exit 0
    fi
fi

TEST_DIR="$REPO_ROOT/.test-chump-brain-cli-$$"
mkdir -p "$TEST_DIR/.chump-locks"
trap 'rm -rf "$TEST_DIR"' EXIT

AMBIENT_LOG="$TEST_DIR/.chump-locks/ambient.jsonl"
touch "$AMBIENT_LOG"

last_run_event() {
    grep '"kind":"chump_brain_cli_run"' "$AMBIENT_LOG" | tail -1
}

# Test 1: `brain stats` succeeds and emits outcome=success.
CHUMP_AMBIENT_LOG="$AMBIENT_LOG" "$CHUMP_BIN" brain stats >/dev/null 2>&1
ev="$(last_run_event)"
[ -n "$ev" ] || fail "Test 1: no chump_brain_cli_run event emitted for 'stats'"
echo "$ev" | grep -q '"subcommand":"stats"' || fail "Test 1: expected subcommand=stats, got: $ev"
echo "$ev" | grep -q '"outcome":"success"' || fail "Test 1: expected outcome=success, got: $ev"
echo "$ev" | grep -q '"failure_class":"none"' || fail "Test 1: expected failure_class=none, got: $ev"
echo "$ev" | grep -q '"duration_ms":[0-9]\+' || fail "Test 1: expected numeric duration_ms, got: $ev"
echo "$ev" | grep -q '"cost_usd":0.0' || fail "Test 1: expected cost_usd=0.0, got: $ev"
pass "Test 1: 'brain stats' emits run event with outcome=success"

# Test 2: `brain query <term>` succeeds and emits outcome=success.
CHUMP_AMBIENT_LOG="$AMBIENT_LOG" "$CHUMP_BIN" brain query some-unlikely-term-xyz >/dev/null 2>&1
ev="$(last_run_event)"
[ -n "$ev" ] || fail "Test 2: no chump_brain_cli_run event emitted for 'query'"
echo "$ev" | grep -q '"subcommand":"query"' || fail "Test 2: expected subcommand=query, got: $ev"
echo "$ev" | grep -q '"outcome":"success"' || fail "Test 2: expected outcome=success, got: $ev"
echo "$ev" | grep -q '"failure_class":"none"' || fail "Test 2: expected failure_class=none, got: $ev"
pass "Test 2: 'brain query <term>' emits run event with outcome=success"

# Test 3: `brain query` with no term is a permanent failure.
CHUMP_AMBIENT_LOG="$AMBIENT_LOG" "$CHUMP_BIN" brain query >/dev/null 2>&1
ev="$(last_run_event)"
[ -n "$ev" ] || fail "Test 3: no chump_brain_cli_run event emitted for missing term"
echo "$ev" | grep -q '"outcome":"error"' || fail "Test 3: expected outcome=error, got: $ev"
echo "$ev" | grep -q '"failure_class":"permanent"' || fail "Test 3: expected failure_class=permanent, got: $ev"
pass "Test 3: 'brain query' with no term emits failure_class=permanent"

# Test 4: unknown subcommand is a permanent failure.
CHUMP_AMBIENT_LOG="$AMBIENT_LOG" "$CHUMP_BIN" brain bogus-sub >/dev/null 2>&1
ev="$(last_run_event)"
[ -n "$ev" ] || fail "Test 4: no chump_brain_cli_run event emitted for unknown subcommand"
echo "$ev" | grep -q '"outcome":"error"' || fail "Test 4: expected outcome=error, got: $ev"
echo "$ev" | grep -q '"failure_class":"permanent"' || fail "Test 4: expected failure_class=permanent, got: $ev"
pass "Test 4: unknown subcommand emits failure_class=permanent"

echo "[test-chump-brain-cli] All tests passed!"
exit 0
