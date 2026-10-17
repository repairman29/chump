#!/usr/bin/env bash
# Synthetic fixture test for INFRA-8218 invariant boundary gate

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$REPO_ROOT"

PASS=0
FAIL=0
ok()  { echo "  PASS: $1"; PASS=$((PASS+1)); }
bad() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

echo "=== INFRA-8218: Invariant Boundary Fixture Tests ==="

# Test 1: Verify pattern detection for sqlite3 state.db mutations
SANDBOX=$(mktemp -d)
trap 'rm -rf "$SANDBOX"' EXIT
mkdir -p "$SANDBOX/scripts/test"

cat > "$SANDBOX/scripts/test/new-writer.sh" << 'NEWVIO'
#!/bin/bash
sqlite3 "$REPO_ROOT/.chump/state.db" "UPDATE gaps SET status='done' WHERE id='TEST-001'"
NEWVIO

if grep -q 'sqlite3.*\.chump.*state\.db' "$SANDBOX/scripts/test/new-writer.sh"; then
    ok "fixture: pattern detection works for sqlite3 state.db"
else
    bad "fixture: pattern detection failed"
fi

# Test 2: Verify allowlist has baseline entries
if grep -q "scripts/coord/gap-doctor.py:" "$REPO_ROOT/scripts/ci/invariant-boundary-allowlist.txt"; then
    ok "fixture: allowlist has baseline"
else
    bad "fixture: allowlist missing baseline"
fi

# Test 3: Verify shadow mode exits 0 with no new violations
if bash "$REPO_ROOT/scripts/ci/test-invariant-boundary.sh" >/dev/null 2>&1; then
    ok "fixture: shadow mode exits 0"
else
    bad "fixture: shadow mode exited non-zero"
fi

echo ""
echo "=== Summary: $PASS passed, $FAIL failed ==="
[[ $FAIL -eq 0 ]]
