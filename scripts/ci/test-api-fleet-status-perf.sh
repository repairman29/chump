#!/usr/bin/env bash
# CI test: /api/fleet-status parallel gh calls don't hang (INFRA-1464).
# Verifies the fix: parallel execution + per-call timeout instead of sequential
# blocking gh pr list calls.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

PASS=0
FAIL=0

# Test 1: tokio::process::Command (async) used for gh in handle_fleet_status.
# Extract the function and check within it specifically.
FLEET_HANDLER=$(awk '/^async fn handle_fleet_status/,/^\}$/' "$REPO_ROOT/src/web_server.rs" 2>/dev/null || true)
if echo "$FLEET_HANDLER" | grep -q "tokio::process::Command"; then
    echo "PASS: tokio::process::Command used for parallel gh calls"
    PASS=$((PASS+1))
else
    echo "FAIL: tokio::process::Command not found in handle_fleet_status"
    FAIL=$((FAIL+1))
fi

# Test 2: futures_util::future::join_all used for fan-out.
if grep -q "join_all" "$REPO_ROOT/src/web_server.rs"; then
    echo "PASS: futures_util::future::join_all fan-out present"
    PASS=$((PASS+1))
else
    echo "FAIL: join_all not found in web_server.rs"
    FAIL=$((FAIL+1))
fi

# Test 3: per-call timeout wired.
if grep -q "CHUMP_FLEET_STATUS_GH_TIMEOUT_S" "$REPO_ROOT/src/web_server.rs"; then
    echo "PASS: CHUMP_FLEET_STATUS_GH_TIMEOUT_S timeout var present"
    PASS=$((PASS+1))
else
    echo "FAIL: CHUMP_FLEET_STATUS_GH_TIMEOUT_S not found"
    FAIL=$((FAIL+1))
fi

# Test 4: no std::process::Command for gh calls in the fleet-status handler.
FLEET_HANDLER2=$(awk '/^async fn handle_fleet_status/,/^}$/' "$REPO_ROOT/src/web_server.rs" 2>/dev/null || true)
if echo "$FLEET_HANDLER2" | grep -q 'std::process::Command::new("gh")'; then
    echo "FAIL: blocking std::process::Command for gh still in handle_fleet_status"
    FAIL=$((FAIL+1))
else
    echo "PASS: no blocking std::process::Command for gh in handle_fleet_status"
    PASS=$((PASS+1))
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
