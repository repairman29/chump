#!/usr/bin/env bash
# test-orphan-process-reap.sh — INFRA-1516: reaper must kill background
# processes (e.g. heartbeat-watcher.sh, chump --acp) whose cwd is inside
# a worktree BEFORE deleting that worktree, not after.
#
# Tests:
#   1. A sleep-loop process running inside a fixture worktree is killed
#      by prune-worktrees.sh before the worktree directory is removed.
#   2. kind=worktree_orphan_process_killed is emitted with pid/cmd/
#      worktree_path/age_seconds.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
PRUNE_SCRIPT="$REPO_ROOT/scripts/ops/prune-worktrees.sh"

pass() { printf '[PASS] %s\n' "$*"; }
fail() { printf '[FAIL] %s\n' "$*" >&2; exit 1; }

[[ -f "$PRUNE_SCRIPT" ]] || fail "prune-worktrees.sh not found at $PRUNE_SCRIPT"

TMP="$(mktemp -d -t test-orphan-process-reap.XXXXXX)"
SLEEP_PID=""
cleanup() {
    [[ -n "$SLEEP_PID" ]] && kill -9 "$SLEEP_PID" 2>/dev/null || true
    rm -rf "$TMP"
}
trap cleanup EXIT

# W-013 immunization (matches test-orphan-worktree-prune.sh): don't let a
# workflow-injected CHUMP_LOCK_DIR redirect lease/ambient checks away from
# this test's fixture repo.
unset CHUMP_REPO CHUMP_LOCK_DIR

FAKE_REPO="$TMP/fake-repo"
mkdir -p "$FAKE_REPO"
git -C "$FAKE_REPO" init -q
git -C "$FAKE_REPO" config user.email "test@chump.bot"
git -C "$FAKE_REPO" config user.name "Test"
echo "init" > "$FAKE_REPO/README"
git -C "$FAKE_REPO" add README
git -C "$FAKE_REPO" commit -q -m "init"

FAKE_LOCKS="$FAKE_REPO/.chump-locks"
mkdir -p "$FAKE_LOCKS"
AMBIENT_FILE="$FAKE_LOCKS/ambient.jsonl"
FAKE_SCAN="$TMP/scan"
mkdir -p "$FAKE_SCAN"

WT="$FAKE_SCAN/chump-orphan-proc-test"
git -C "$FAKE_REPO" worktree add "$WT" -b "chump/orphan-proc-test" -q 2>/dev/null

# ── Spawn a background "sleep loop" whose cwd is inside the worktree,
#    simulating a heartbeat-watcher.sh / chump --acp orphan.
( cd "$WT" && exec sh -c 'while true; do sleep 1; done' ) &
SLEEP_PID=$!
sleep 1
kill -0 "$SLEEP_PID" 2>/dev/null || fail "setup: sleep-loop process did not start"
pass "setup: sleep-loop process $SLEEP_PID running with cwd inside $WT"

# Sanity: the process is actually discoverable via lsof/pgrep on this worktree
# path before we invoke the reaper (guards against a bad test fixture).
if command -v lsof &>/dev/null; then
    lsof +D "$WT" 2>/dev/null | grep -q "$SLEEP_PID" \
        || pgrep -f "$WT" 2>/dev/null | grep -q "$SLEEP_PID" \
        || fail "setup: neither lsof nor pgrep can see $SLEEP_PID under $WT"
else
    pgrep -f "$WT" 2>/dev/null | grep -q "$SLEEP_PID" \
        || fail "setup: pgrep cannot see $SLEEP_PID under $WT"
fi

# ── Run the reaper (real run, not dry-run; no open PR check needed).
CHUMP_SKIP_ORPHAN_PRUNE=0 CHUMP_SKIP_PR_CHECK=1 \
    env -u GIT_DIR -u GIT_WORK_TREE \
    bash -c "cd '$FAKE_REPO' && bash '$PRUNE_SCRIPT' --scan-dir '$FAKE_SCAN'" 2>&1 || true

# ── Assert 1: the worktree directory is gone.
if [[ -d "$WT" ]]; then
    fail "worktree should have been pruned (still exists: $WT)"
fi
pass "worktree directory removed"

# ── Assert 2: the process was actually killed (not orphaned).
sleep 1
if kill -0 "$SLEEP_PID" 2>/dev/null; then
    fail "orphan process $SLEEP_PID is still alive after reaper ran"
fi
pass "orphan process $SLEEP_PID killed by reaper before/during deletion"

# ── Assert 3: ambient event emitted with the expected fields.
if [[ -f "$AMBIENT_FILE" ]] && grep -q "worktree_orphan_process_killed" "$AMBIENT_FILE"; then
    EVT_LINE="$(grep "worktree_orphan_process_killed" "$AMBIENT_FILE" | tail -1)"
    for field in '"pid"' '"cmd"' '"worktree_path"' '"age_seconds"'; do
        echo "$EVT_LINE" | grep -q "$field" || fail "ambient event missing field $field: $EVT_LINE"
    done
    pass "kind=worktree_orphan_process_killed emitted with pid/cmd/worktree_path/age_seconds"
else
    fail "kind=worktree_orphan_process_killed not found in $AMBIENT_FILE"
fi

echo ""
echo "All INFRA-1516 orphan-process-reap checks passed (3/3)."
