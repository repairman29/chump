#!/usr/bin/env bash
# INFRA-651: verify operator_presence tests pass under parallel cargo-test execution.
# Runs cargo test for the operator_presence module at N=1,2,4,8 threads and asserts
# no flaky behavior (exit 0 each time).
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

FILTER="operator_presence"
PASS=0
FAIL=0

for N in 1 2 4 8; do
    echo "==> cargo test --test-threads=$N (filter: $FILTER)"
    if cargo test "$FILTER" -- --test-threads="$N" 2>&1; then
        PASS=$((PASS + 1))
    else
        echo "FAIL at --test-threads=$N" >&2
        FAIL=$((FAIL + 1))
    fi
done

echo "==> Results: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
    echo "ERROR: flaky behavior detected under parallel execution" >&2
    exit 1
fi
echo "OK: operator_presence tests stable across all thread counts"
