#!/usr/bin/env bash
# scripts/ci/test-changes-job-self-hosted.sh — INFRA-1537
#
# Asserts the `changes` job in .github/workflows/ci.yml uses the lane-aware
# self-hosted routing pattern, with a per-lane `CHUMP_SELF_HOSTED_CHANGES`
# opt-out. Compatibility-check with the INFRA-1567 per-lane scheme.

set -uo pipefail

PASS=0
FAIL=0
FAILS=()
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); FAILS+=("$1"); }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
CI="$REPO_ROOT/.github/workflows/ci.yml"

echo "=== INFRA-1537 changes-job self-hosted routing ==="

# Find the `changes:` job block and assert its runs-on matches the lane-pattern.
CHANGES_BLOCK="$(grep -A 20 '^  changes:' "$CI" | head -22)"

if echo "$CHANGES_BLOCK" | grep -q "vars.CHUMP_SELF_HOSTED_ENABLED == 'true'"; then
    ok "changes job runs-on checks master CHUMP_SELF_HOSTED_ENABLED"
else
    fail "changes job runs-on missing master check"
fi

if echo "$CHANGES_BLOCK" | grep -q "vars.CHUMP_SELF_HOSTED_CHANGES != 'false'"; then
    ok "changes job runs-on checks per-lane CHUMP_SELF_HOSTED_CHANGES"
else
    fail "changes job runs-on missing per-lane CHUMP_SELF_HOSTED_CHANGES var"
fi

if echo "$CHANGES_BLOCK" | grep -q "macos-arm64"; then
    ok "changes job routes to macos-arm64 self-hosted lane"
else
    fail "changes job missing macos-arm64 label"
fi

if echo "$CHANGES_BLOCK" | grep -q "ubuntu-latest"; then
    ok "changes job retains ubuntu-latest fallback"
else
    fail "changes job lost ubuntu-latest fallback"
fi

# Master kill-switch (CHUMP_SELF_HOSTED_ENABLED='false' → ubuntu)
# This is structural — the && chain ensures master='false' short-circuits.
if echo "$CHANGES_BLOCK" | grep -qE "CHUMP_SELF_HOSTED_ENABLED == 'true' &&"; then
    ok "master='false' kill-switch preserved (true && lane pattern)"
else
    fail "master kill-switch missing"
fi

# Backwards-compat: bare `runs-on: ubuntu-latest` should NOT still be on the
# `changes` job (we're migrating it).
if echo "$CHANGES_BLOCK" | grep -qE "^[[:space:]]+runs-on:[[:space:]]+ubuntu-latest[[:space:]]*$"; then
    fail "changes job still has bare ubuntu-latest (migration incomplete)"
else
    ok "changes job no longer hardcoded to ubuntu-latest"
fi

echo ""
echo "=== Summary: $PASS passed, $FAIL failed ==="
if (( FAIL > 0 )); then
    for f in "${FAILS[@]}"; do printf '  - %s\n' "$f"; done
    exit 1
fi
echo "PASS"
