#!/usr/bin/env bash
# test-queue-driver-iter-no-repeat.sh — INFRA-2271
#
# Asserts queue-driver's DIRTY-PR loop doesn't get stuck re-attempting the
# same skipped PR. Before this fix, semantic-skipped PRs consumed MAX budget
# → next invocation re-picked first DIRTY (same one) → infinite skip-loop.
#
# After: semantic-skip continues to next DIRTY in same run; only successful
# resolution counts toward MAX budget.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
QD="$REPO_ROOT/scripts/coord/queue-driver.sh"

if [[ ! -f "$QD" ]]; then
    echo "FAIL: $QD missing"
    exit 1
fi

pass=0; fail=0

# Test 1: ambient kind=queue_driver_iter_attempted emitted on each PR (both outcomes)
if grep -q 'kind":"queue_driver_iter_attempted"' "$QD" 2>/dev/null; then
    echo "PASS 1: queue_driver_iter_attempted emit present"
    pass=$((pass+1))
else
    echo "FAIL 1: missing queue_driver_iter_attempted emit"
    fail=$((fail+1))
fi

# Test 2: outcome=resolved branch increments count (success path counts toward MAX)
if grep -B2 -A4 'outcome":"resolved' "$QD" 2>/dev/null | grep -q 'count=\$((count + 1))'; then
    echo "PASS 2: resolved-outcome increments count (MAX budget)"
    pass=$((pass+1))
else
    echo "FAIL 2: resolved path missing count increment"
    fail=$((fail+1))
fi

# Test 3: outcome=skipped_semantic branch does NOT increment count (key fix)
# Look for the structure: skipped branch should NOT have `count=$((count + 1))` between echo and skipped++
skipped_block=$(awk '/leaving #.*for human owner — continuing/,/skipped=\$\(\(skipped \+ 1\)\)/' "$QD" 2>/dev/null)
if echo "$skipped_block" | grep -q 'count=\$((count + 1))'; then
    echo "FAIL 3: skipped path STILL increments count — bug not fixed"
    fail=$((fail+1))
else
    echo "PASS 3: skipped path correctly does NOT consume MAX budget"
    pass=$((pass+1))
fi

# Test 4: skipped counter is tracked + reported in summary
if grep -q 'skipped \$skipped semantic-conflict' "$QD" 2>/dev/null; then
    echo "PASS 4: summary line reports skipped count"
    pass=$((pass+1))
else
    echo "FAIL 4: missing skipped-count in summary"
    fail=$((fail+1))
fi

# Test 5: continuing to next DIRTY (echo says so for operator visibility)
if grep -q "continuing to next DIRTY" "$QD" 2>/dev/null; then
    echo "PASS 5: continuing-to-next message for operator visibility"
    pass=$((pass+1))
else
    echo "FAIL 5: missing 'continuing to next DIRTY' message"
    fail=$((fail+1))
fi

# Test 6: event-registry-reserved.txt contains queue_driver_iter_attempted
if grep -q 'queue_driver_iter_attempted' "$REPO_ROOT/scripts/ci/event-registry-reserved.txt" 2>/dev/null; then
    echo "PASS 6: queue_driver_iter_attempted registered in event-registry-reserved.txt"
    pass=$((pass+1))
else
    echo "FAIL 6: queue_driver_iter_attempted not in event-registry-reserved.txt"
    fail=$((fail+1))
fi

echo
if [[ "$fail" -eq 0 ]]; then
    echo "test-queue-driver-iter-no-repeat: ALL $pass passed"
    exit 0
else
    echo "test-queue-driver-iter-no-repeat: $pass passed, $fail failed"
    exit 1
fi
