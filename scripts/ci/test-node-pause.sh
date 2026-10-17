#!/usr/bin/env bash
# RESILIENT-1614: verify that `chump node pause|resume` commands exist and are wired.
#
# This is a smoke test for the CLI dispatch. Full functional testing
# (node.env persistence, sentinel creation) is covered by Rust unit tests
# in src/node_cmd.rs.

set -euo pipefail

failures=0
pass() { printf '  ok   %s\n' "$*"; }
fail() { printf '  FAIL %s\n' "$*"; failures=$((failures + 1)); }

# Test that the commands exist and show usage without blowing up
if chump node pause --help 2>&1 | grep -q "Usage"; then
  pass "chump node pause command exists and shows usage"
else
  fail "chump node pause command does not respond to --help"
fi

if chump node resume --help 2>&1 | grep -q "Usage"; then
  pass "chump node resume command exists and shows usage"
else
  fail "chump node resume command does not respond to --help"
fi

# Test that pause requires --reason
if chump node pause 2>&1 | grep -qi "reason"; then
  pass "chump node pause correctly requires --reason flag"
else
  fail "chump node pause does not validate --reason requirement"
fi

if [ "$failures" -eq 0 ]; then
  echo "PASS: node pause|resume CLI dispatch contract holds"
  exit 0
fi
echo "FAIL: $failures assertion(s) failed" >&2
exit 1
