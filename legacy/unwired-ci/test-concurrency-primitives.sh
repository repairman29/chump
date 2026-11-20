#!/usr/bin/env bash
# scripts/ci/test-concurrency-primitives.sh — INFRA-4608
# Self-test for scripts/lib/concurrency-primitives.sh: acquire, release,
# re-acquire without error, plus a negative case for double-acquire.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck source=scripts/lib/concurrency-primitives.sh
source "$REPO_ROOT/scripts/lib/concurrency-primitives.sh"

export CHUMP_LOCK_PRIMITIVE_DIR
CHUMP_LOCK_PRIMITIVE_DIR="$(mktemp -d)"
trap 'rm -rf "$CHUMP_LOCK_PRIMITIVE_DIR"' EXIT

PASS=0
FAIL=0

_check() {
    local label="$1" expected="$2" actual="$3"
    if [[ "$actual" -eq "$expected" ]]; then
        echo "PASS [$label]"
        PASS=$(( PASS + 1 ))
    else
        echo "FAIL [$label]: expected exit $expected, got $actual"
        FAIL=$(( FAIL + 1 ))
    fi
}

echo "=== INFRA-4608 concurrency-primitives self-test ==="

# 1. Acquire a fresh lock — must succeed.
acquire_lock testlock 5
_check "acquire fresh lock" 0 $?

# 2. Release it — must succeed.
release_lock testlock
_check "release held lock" 0 $?

# 3. Re-acquire the same name after release — must succeed without error.
acquire_lock testlock 5
_check "re-acquire after release" 0 $?

# 4. Release again to leave a clean final state.
release_lock testlock
_check "release re-acquired lock" 0 $?

# 5. Releasing a lock never held must fail non-zero (no crash).
release_lock never-held
rc=$?
if [[ "$rc" -ne 0 ]]; then
    echo "PASS [release unheld lock returns non-zero]"
    PASS=$(( PASS + 1 ))
else
    echo "FAIL [release unheld lock returns non-zero]: got 0"
    FAIL=$(( FAIL + 1 ))
fi

# 6. A second process holding the lock blocks this process (non-blocking probe).
(
    # shellcheck source=scripts/lib/concurrency-primitives.sh
    source "$REPO_ROOT/scripts/lib/concurrency-primitives.sh"
    acquire_lock crosslock 5
    sleep 2
) &
child_pid=$!
sleep 0.5
acquire_lock crosslock 0
rc=$?
wait "$child_pid"
if [[ "$rc" -ne 0 ]]; then
    echo "PASS [non-blocking acquire fails while held elsewhere]"
    PASS=$(( PASS + 1 ))
else
    echo "FAIL [non-blocking acquire fails while held elsewhere]: got 0"
    FAIL=$(( FAIL + 1 ))
    release_lock crosslock
fi

# 7. After the other holder releases, we can acquire it.
acquire_lock crosslock 5
_check "acquire after other holder released" 0 $?
release_lock crosslock

echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
