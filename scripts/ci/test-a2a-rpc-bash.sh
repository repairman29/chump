#!/usr/bin/env bash
# test-a2a-rpc-bash.sh — INFRA-1119 AC #6 smoke for rpc.sh.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/coord/rpc.sh"

[[ -x "$SCRIPT" ]] || { echo "FAIL: $SCRIPT not executable"; exit 1; }

echo "Test 1: --help shows usage"
out=$("$SCRIPT" --help 2>&1)
if echo "$out" | grep -q "rpc.sh call" && echo "$out" | grep -q "session"; then
    echo "  PASS"
else
    echo "  FAIL: --help missing expected content"; exit 1
fi

echo "Test 2: unknown command exits 2"
"$SCRIPT" bogus 2>/dev/null && rc=0 || rc=$?
if [[ "$rc" -eq 2 ]]; then echo "  PASS"; else echo "  FAIL: rc=$rc"; exit 1; fi

echo "Test 3: wrong arg count on 'call' exits 2"
"$SCRIPT" call 2>/dev/null && rc=0 || rc=$?
if [[ "$rc" -eq 2 ]]; then echo "  PASS"; else echo "  FAIL: rc=$rc"; exit 1; fi

echo "Test 4: lib import works"
# Just confirm the script can read the lib without erroring on the source.
out=$("$SCRIPT" call test-target ask-eta '{"gap_id":"X"}' 1 2>&1 || true)
# Should not contain "missing" library error; may timeout (expected — no peer)
if echo "$out" | grep -q "missing"; then
    echo "  FAIL: lib not found: $out"; exit 1
else
    echo "  PASS (lib imports cleanly, transport active)"
fi

echo
echo "All 4 a2a-rpc-bash smoke tests passed."
