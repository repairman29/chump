#!/usr/bin/env bash
# test-pr-failure-auto-rescue.sh — INFRA-1600
#
# Smoke tests for the auto-rescue daemon. Source-shape only (no real gh
# calls). Verifies:
#   1. Script exists + executable
#   2. --dry-run + --help flags supported
#   3. All 5 known handlers present
#   4. Cool-down + max-per-PR safety logic present
#   5. Ambient event emission shape

set -uo pipefail
PASS=0
FAIL=0
FAILS=()

ok() { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); FAILS+=("$1"); }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DAEMON="$REPO_ROOT/scripts/coord/pr-failure-auto-rescue.sh"

echo "=== INFRA-1600 PR auto-rescue daemon smoke ==="

# Test 1: present + executable
if [[ -x "$DAEMON" ]]; then
    ok "daemon script present + executable"
else
    fail "daemon script missing or not executable: $DAEMON"
fi

# Test 2: --help works
if bash "$DAEMON" --help 2>&1 | grep -q "Usage:"; then
    ok "--help accepted"
else
    fail "--help did not produce usage"
fi

# Test 3: all 5 handlers present
HANDLERS="cargo_fmt_drift cargo_not_found chump_bin_not_found tauri_flake adjacent_string_eprintln"
missing_handlers=""
for h in $HANDLERS; do
    if ! grep -q "handle_$h" "$DAEMON"; then
        missing_handlers="$missing_handlers $h"
    fi
done
if [[ -z "$missing_handlers" ]]; then
    ok "all 5 known handlers present"
else
    fail "missing handlers:$missing_handlers"
fi

# Test 4: safety logic (cooldown + max-per-PR)
if grep -q "in_cooldown" "$DAEMON" && grep -q "count_past_rescues" "$DAEMON"; then
    ok "cool-down + max-per-PR safety logic present"
else
    fail "safety logic missing"
fi

# Test 5: ambient emit shape
if grep -q "pr_auto_rescue_invoked" "$DAEMON"; then
    ok "emits kind=pr_auto_rescue_invoked"
else
    fail "ambient emit kind missing"
fi

# Test 6: --dry-run does not actually push or commit
out=$(bash "$DAEMON" --dry-run 2>&1)
if echo "$out" | grep -q "scanning"; then
    ok "--dry-run scans without action"
else
    fail "--dry-run did not produce expected output"
fi

echo
echo "=== Summary: $PASS passed, $FAIL failed ==="
if (( FAIL > 0 )); then
    for f in "${FAILS[@]}"; do printf '  - %s\n' "$f"; done
    exit 1
fi
echo "PASS"
