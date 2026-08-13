#!/usr/bin/env bash
# test-infra-2984-smoke.sh — INFRA-2984 smoke test.
#
# INFRA-2984 shipped with no description beyond "verify it works" —
# this verifies the chump CLI's core commands are functional.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$REPO_ROOT"

echo "Test 1: chump --version prints a version string"
out="$(chump --version 2>&1)"
[[ "$out" == chump\ * ]] && echo "  PASS" || { echo "  FAIL: $out"; exit 1; }

echo "Test 2: chump --build-info --json emits valid JSON"
out="$(chump --build-info --json 2>&1)"
echo "$out" | python3 -c 'import json,sys; json.load(sys.stdin)' \
  && echo "  PASS" || { echo "  FAIL: $out"; exit 1; }

echo "Test 3: chump gap show <existing gap> succeeds"
out="$(chump gap show INFRA-2984 2>&1)"
[[ "$out" == *"INFRA-2984"* ]] && echo "  PASS" || { echo "  FAIL: $out"; exit 1; }

echo "Test 4: chump gap preflight warns on a nonexistent gap"
out="$(chump gap preflight INFRA-999999999 2>&1)"
[[ "$out" == *"not found in state.db"* ]] && echo "  PASS" || { echo "  FAIL: $out"; exit 1; }

echo ""
echo "All INFRA-2984 smoke tests passed."
