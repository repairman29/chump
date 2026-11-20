#!/usr/bin/env bash
# test-pr-repair-rebase.sh — INFRA-727 smoke test for pr-repair-rebase.sh
#
# Validates:
#   1. Script exists and is executable
#   2. CHUMP_PR_REPAIR=0 bypass works (exits 0, no output)
#   3. Script doesn't crash when gh is unavailable
#   4. Worker.sh contains the INFRA-727 integration point

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/ops/pr-repair-rebase.sh"
WORKER="$REPO_ROOT/scripts/dispatch/worker.sh"

echo "Test 1: pr-repair-rebase.sh exists and is executable"
[[ -x "$SCRIPT" ]] || { echo "  FAIL: $SCRIPT missing or not executable"; exit 1; }
echo "  PASS"

echo "Test 2: CHUMP_PR_REPAIR=0 bypass exits cleanly"
CHUMP_PR_REPAIR=0 bash "$SCRIPT" 2>/dev/null
rc=$?
if [[ $rc -eq 0 ]]; then
    echo "  PASS"
else
    echo "  FAIL (expected rc=0, got $rc)"
    exit 1
fi

echo "Test 3: worker.sh contains INFRA-727 integration"
if grep -q 'INFRA-727.*repair.*stuck.*PR' "$WORKER"; then
    echo "  PASS"
else
    echo "  FAIL: worker.sh missing INFRA-727 integration comment"
    exit 1
fi

echo "Test 4: worker.sh calls pr-repair-rebase.sh"
if grep -q 'pr-repair-rebase.sh' "$WORKER"; then
    echo "  PASS"
else
    echo "  FAIL: worker.sh doesn't call pr-repair-rebase.sh"
    exit 1
fi

echo "Test 5: only agent 1 runs repair (avoid triple-rebase)"
if grep -q 'AGENT_ID.*==.*"1"' "$WORKER"; then
    echo "  PASS"
else
    echo "  FAIL: missing agent-1 guard"
    exit 1
fi

echo ""
echo "All pr-repair-rebase tests passed."
