#!/usr/bin/env bash
# scripts/ci/test-pr-stuck-cluster-observability.sh — INFRA-2754
#
# Smoke-test: pr-stuck-cluster-detector.sh emits kind=pr_stuck_cluster_detector_run
# on every invocation (no-op path and cluster-detected path), with fields:
# outcome, stuck_pr_count, duration_ms, gap_reserve_calls.
#
# Runnable standalone:
#   scripts/ci/test-pr-stuck-cluster-observability.sh
#
# Exit codes:
#   0 = all tests pass
#   1 = test failure

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd -P)"

fail() {
    echo "[test-pr-stuck-cluster-observability] FAIL: $*" >&2
    exit 1
}

pass() {
    echo "[test-pr-stuck-cluster-observability] PASS: $*"
}

setup_test_env() {
    local test_dir="$REPO_ROOT/.test-pr-cluster-obs-$$"
    mkdir -p "$test_dir/.chump-locks/.cluster-sent"
    echo "$test_dir"
}

cleanup_test_env() {
    local test_dir="$1"
    rm -rf "$test_dir"
}

last_run_event() {
    local ambient_path="$1"
    grep '"kind":"pr_stuck_cluster_detector_run"' "$ambient_path" | tail -1
}

# Test 1: no-stuck-events path emits a run event with outcome=no_op.
test_no_op_run_event() {
    local test_dir
    test_dir="$(setup_test_env)"
    trap "cleanup_test_env '$test_dir'" RETURN

    touch "$test_dir/.chump-locks/ambient.jsonl"

    LOCK_DIR="$test_dir/.chump-locks" bash "$REPO_ROOT/scripts/coord/pr-stuck-cluster-detector.sh" >/dev/null 2>&1

    local ev
    ev="$(last_run_event "$test_dir/.chump-locks/ambient.jsonl")"
    [ -n "$ev" ] || fail "Test 1: no pr_stuck_cluster_detector_run event emitted"

    echo "$ev" | grep -q '"outcome":"no_op"' || fail "Test 1: expected outcome=no_op, got: $ev"
    echo "$ev" | grep -q '"stuck_pr_count":0' || fail "Test 1: expected stuck_pr_count=0, got: $ev"
    echo "$ev" | grep -q '"duration_ms":[0-9]\+' || fail "Test 1: expected numeric duration_ms, got: $ev"
    echo "$ev" | grep -q '"gap_reserve_calls":0' || fail "Test 1: expected gap_reserve_calls=0, got: $ev"

    pass "Test 1: no-stuck-events path emits run event with outcome=no_op"
}

# Test 2: cluster-detected (dry-run, no --apply) path emits run event with
# outcome=dry_run, gap_reserve_calls=0 (no mutation happened), correct count.
test_cluster_detected_run_event() {
    local test_dir
    test_dir="$(setup_test_env)"
    trap "cleanup_test_env '$test_dir'" RETURN

    local ts_iso
    ts_iso="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

    cat > "$test_dir/.chump-locks/ambient.jsonl" << EOF
{"ts":"$ts_iso","kind":"pr_stuck","pr":1001,"gap":"INFRA-100"}
{"ts":"$ts_iso","kind":"pr_stuck","pr":1002,"gap":"INFRA-101"}
{"ts":"$ts_iso","kind":"pr_stuck","pr":1003,"gap":"INFRA-102"}
EOF

    LOCK_DIR="$test_dir/.chump-locks" bash "$REPO_ROOT/scripts/coord/pr-stuck-cluster-detector.sh" >/dev/null 2>&1

    local ev
    ev="$(last_run_event "$test_dir/.chump-locks/ambient.jsonl")"
    [ -n "$ev" ] || fail "Test 2: no pr_stuck_cluster_detector_run event emitted"

    echo "$ev" | grep -q '"outcome":"dry_run"' || fail "Test 2: expected outcome=dry_run, got: $ev"
    echo "$ev" | grep -q '"stuck_pr_count":3' || fail "Test 2: expected stuck_pr_count=3, got: $ev"
    echo "$ev" | grep -q '"gap_reserve_calls":0' || fail "Test 2: expected gap_reserve_calls=0 (no --apply), got: $ev"

    pass "Test 2: cluster-detected (dry-run) path emits run event with correct fields"
}

echo "[test-pr-stuck-cluster-observability] Starting tests..."

test_no_op_run_event
test_cluster_detected_run_event

echo "[test-pr-stuck-cluster-observability] All tests passed!"
exit 0
