#!/usr/bin/env bash
# test-orphan-process-reap.sh — INFRA-1516: orphan-process reaper smoke test
#
# The worktree-prune reapers (scripts/coord/worktree-prune.sh,
# scripts/ops/prune-worktrees.sh) must kill any background process still
# running inside a worktree BEFORE deleting the worktree directory — else
# heartbeat-watcher.sh / `chump --acp` invocations survive with a dangling
# cwd, contributing to slow process-table scans and zombie lease confusion.
#
# Tests the shared primitive scripts/lib/worktree-iter.sh::wt_kill_orphan_processes:
#   1. Spawn a sleep loop with cwd inside a fixture worktree.
#   2. Call wt_kill_orphan_processes on the fixture path.
#   3. Assert the process is dead BEFORE the directory is removed.
#   4. Assert kind=worktree_orphan_process_killed was emitted to ambient.jsonl.

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

pass() { printf '[PASS] %s\n' "$*"; }
fail() { printf '[FAIL] %s\n' "$*" >&2; exit 1; }

TMP="$(mktemp -d -t test-orphan-process-reap.XXXXXX)"
cleanup() {
    [[ -n "${SLEEP_PID:-}" ]] && kill -9 "$SLEEP_PID" 2>/dev/null || true
    rm -rf "$TMP"
}
trap cleanup EXIT

FAKE_REPO="$TMP/fake-repo"
mkdir -p "$FAKE_REPO/.chump-locks"
FIXTURE_WT="$TMP/fixture-worktree"
mkdir -p "$FIXTURE_WT"

# shellcheck source=../lib/worktree-iter.sh
source "$SCRIPT_DIR/../lib/worktree-iter.sh"
REAPER_NAME="test-orphan-process-reap"
REAPER_REPO_ROOT="$FAKE_REPO"
export REAPER_NAME REAPER_REPO_ROOT
CHUMP_AMBIENT_LOG="$FAKE_REPO/.chump-locks/ambient.jsonl"
export CHUMP_AMBIENT_LOG

# ── Test 1: spawn sleep loop, assert it's alive before reaping ───────────────
(cd "$FIXTURE_WT" && exec bash -c 'while true; do sleep 1; done') &
SLEEP_PID=$!
sleep 0.5
kill -0 "$SLEEP_PID" 2>/dev/null || fail "Test 1 setup: fixture sleep loop (pid $SLEEP_PID) did not start"
pass "Test 1: fixture sleep loop running inside $FIXTURE_WT (pid $SLEEP_PID)"

# ── Test 2: reaper kills the process before directory removal ────────────────
wt_kill_orphan_processes "$FIXTURE_WT"

if kill -0 "$SLEEP_PID" 2>/dev/null; then
    fail "Test 2: process $SLEEP_PID still alive after wt_kill_orphan_processes"
fi
pass "Test 2: wt_kill_orphan_processes killed pid $SLEEP_PID"

# Directory must still exist at this point — the reaper only kills
# processes, it never deletes anything itself. The CALLER (prune script)
# is responsible for removal, and must do so only AFTER the kill returns.
[[ -d "$FIXTURE_WT" ]] || fail "Test 2: fixture directory unexpectedly removed by wt_kill_orphan_processes"
pass "Test 2: process killed BEFORE directory removal (directory still present)"

# Now simulate the caller's next step: remove the directory. Should be
# uneventful since the process is already gone.
rm -rf "$FIXTURE_WT"
[[ -d "$FIXTURE_WT" ]] && fail "Test 2: fixture directory removal failed"
pass "Test 2: directory removal after kill succeeded cleanly"

# ── Test 3: ambient kind=worktree_orphan_process_killed emitted ──────────────
if [[ -f "$CHUMP_AMBIENT_LOG" ]] && grep -q "worktree_orphan_process_killed" "$CHUMP_AMBIENT_LOG"; then
    pass "Test 3: kind=worktree_orphan_process_killed emitted to ambient.jsonl"
else
    fail "Test 3: kind=worktree_orphan_process_killed not found in $CHUMP_AMBIENT_LOG"
fi

# Sanity: event carries pid + cmd + age_seconds fields per AC5.
EVENT_LINE="$(grep "worktree_orphan_process_killed" "$CHUMP_AMBIENT_LOG" | tail -1)"
echo "$EVENT_LINE" | grep -q '"pid":' || fail "Test 3: event missing pid field: $EVENT_LINE"
echo "$EVENT_LINE" | grep -q '"cmd":' || fail "Test 3: event missing cmd field: $EVENT_LINE"
echo "$EVENT_LINE" | grep -q '"age_seconds":' || fail "Test 3: event missing age_seconds field: $EVENT_LINE"
pass "Test 3: event carries pid, cmd, and age_seconds fields"

unset SLEEP_PID
echo ""
echo "All INFRA-1516 orphan-process-reap checks passed (3/3)."
