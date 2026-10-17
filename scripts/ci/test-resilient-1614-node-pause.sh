#!/usr/bin/env bash
# scripts/ci/test-resilient-1614-node-pause.sh — RESILIENT-1614
#
# Test that `chump node pause|resume` works and that paused nodes skip organ work.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# Temporary test state dir.
STATE_DIR="$(mktemp -d)"
trap 'rm -rf "$STATE_DIR"' EXIT

export CHUMP_STATE_DIR="$STATE_DIR"
mkdir -p "$STATE_DIR/.chump-locks"

# Helper to run the node command with the test state dir.
chump_node() {
    CHUMP_STATE_DIR="$STATE_DIR" "${CHUMP_BIN:-$REPO_ROOT/target/debug/chump}" node "$@" 2>&1 || true
}

# Helper to check if paused.
node_is_paused() {
    local node_env="$STATE_DIR/node.env"
    [[ -f "$node_env" ]] || return 1
    grep -q "^export CHUMP_NODE_MODE=paused" "$node_env" 2>/dev/null && return 0
    grep -q "^CHUMP_NODE_MODE=paused" "$node_env" 2>/dev/null && return 0
    return 1
}

# Helper to check if the sentinel exists.
pause_sentinel_exists() {
    [[ -f "$STATE_DIR/fleet-paused" ]]
}

# Test 1: Initial state should not be paused.
echo "Test 1: Initial state is not paused..."
node_is_paused && { echo "FAIL: node unexpectedly paused at start"; exit 1; }
pause_sentinel_exists && { echo "FAIL: sentinel unexpectedly exists at start"; exit 1; }
echo "PASS"

# Test 2: Pause the node.
echo "Test 2: Pause the node..."
output=$(chump_node pause --reason "test pause")
echo "$output" | grep -q "Node paused" || { echo "FAIL: pause did not output success message"; exit 1; }
node_is_paused || { echo "FAIL: node not paused after pause command"; exit 1; }
pause_sentinel_exists || { echo "FAIL: sentinel not created after pause"; exit 1; }
echo "PASS"

# Test 3: Check that node.env has CHUMP_NODE_WORK_ENABLED=0.
echo "Test 3: Check node.env has work disabled..."
grep -q "^export CHUMP_NODE_WORK_ENABLED=0" "$STATE_DIR/node.env" || \
  { echo "FAIL: CHUMP_NODE_WORK_ENABLED not set to 0"; exit 1; }
echo "PASS"

# Test 4: Resume the node.
echo "Test 4: Resume the node..."
output=$(chump_node resume)
echo "$output" | grep -q "Node resumed" || { echo "FAIL: resume did not output success message"; exit 1; }
node_is_paused && { echo "FAIL: node still paused after resume"; exit 1; }
pause_sentinel_exists && { echo "FAIL: sentinel still exists after resume"; exit 1; }
echo "PASS"

# Test 5: Check that node.env has work enabled.
echo "Test 5: Check node.env has work enabled..."
grep -q "^export CHUMP_NODE_WORK_ENABLED=1" "$STATE_DIR/node.env" || \
  grep -q "^export CHUMP_NODE_MODE=work-ready" "$STATE_DIR/node.env" || \
  { echo "FAIL: work not re-enabled after resume"; exit 1; }
echo "PASS"

# Test 6: Test pause-check library.
echo "Test 6: Test pause-check library..."
_pause_lib="$REPO_ROOT/scripts/ops/lib/node-pause-check.sh"
if [[ -f "$_pause_lib" ]]; then
    # Source it and test.
    source "$_pause_lib"

    # Should not be paused now.
    _node_pause_check_is_paused && { echo "FAIL: pause check found paused when resumed"; exit 1; }

    # Pause it again.
    chump_node pause --reason "test check" >/dev/null

    # Should be paused now.
    _node_pause_check_is_paused || { echo "FAIL: pause check did not find paused"; exit 1; }

    echo "PASS"
else
    echo "SKIP: pause-check lib not found"
fi

echo ""
echo "All tests passed!"
