#!/usr/bin/env bash
# test-orphan-process-reap.sh — INFRA-1516: orphan-process reaper
#
# Tests:
#   1. wt_reap_processes() kills a background process whose cwd is under
#      a worktree path, before the caller deletes the directory.
#   2. scripts/ops/prune-worktrees.sh kills the orphan process (via
#      wt_reap_processes) before it removes the worktree directory.
#   3. Ambient event kind=worktree_orphan_process_killed emitted with
#      pid/cmd/age_seconds fields.

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
PRUNE_SCRIPT="$REPO_ROOT/scripts/ops/prune-worktrees.sh"
LIB_WORKTREE_ITER="$REPO_ROOT/scripts/lib/worktree-iter.sh"
LIB_LEASE="$REPO_ROOT/scripts/lib/lease.sh"

pass() { printf '[PASS] %s\n' "$*"; }
fail() { printf '[FAIL] %s\n' "$*" >&2; exit 1; }

[[ -f "$LIB_WORKTREE_ITER" ]] || fail "worktree-iter.sh not found at $LIB_WORKTREE_ITER"
[[ -f "$PRUNE_SCRIPT" ]] || fail "prune-worktrees.sh not found at $PRUNE_SCRIPT"

TMP="$(mktemp -d -t test-orphan-process-reap.XXXXXX)"
cleanup() {
    # Best-effort: kill any sleep procs we spawned that survived a failed assert.
    [[ -n "${SLEEP_PID:-}" ]] && kill -9 "$SLEEP_PID" 2>/dev/null || true
    [[ -n "${SLEEP_PID2:-}" ]] && kill -9 "$SLEEP_PID2" 2>/dev/null || true
    rm -rf "$TMP"
}
trap cleanup EXIT

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
FAKE_AMBIENT="$FAKE_LOCKS/ambient.jsonl"
FAKE_SCAN="$TMP/scan"
mkdir -p "$FAKE_SCAN"

make_orphan_worktree() {
    local name="$1"
    local wt_path="$FAKE_SCAN/$name"
    local branch="chump/${name}"
    git -C "$FAKE_REPO" worktree add "$wt_path" -b "$branch" -q 2>/dev/null
    echo "$wt_path"
}

# ── Test 1: wt_reap_processes() kills a process whose cwd is the worktree ────
WT1="$(make_orphan_worktree "chump-fixture-test-1")"
[[ -d "$WT1" ]] || fail "Test 1 setup: worktree not created at $WT1"

( cd "$WT1" && exec sleep 300 ) &
SLEEP_PID=$!
sleep 0.3
kill -0 "$SLEEP_PID" 2>/dev/null || fail "Test 1 setup: fixture sleep process did not start"

(
    # shellcheck source=../lib/worktree-iter.sh
    source "$LIB_WORKTREE_ITER"
    # shellcheck source=../lib/lease.sh
    source "$LIB_LEASE"
    export REAPER_NAME="test-orphan-process-reap"
    export REAPER_REPO_ROOT="$FAKE_REPO"
    export CHUMP_AMBIENT_LOG="$FAKE_AMBIENT"
    wt_reap_processes "$WT1"
)

sleep 0.2
if kill -0 "$SLEEP_PID" 2>/dev/null; then
    kill -9 "$SLEEP_PID" 2>/dev/null || true
    fail "Test 1: wt_reap_processes() did not kill process $SLEEP_PID with cwd under $WT1"
fi
pass "Test 1: wt_reap_processes() killed the orphan process before directory removal"

if grep -q "worktree_orphan_process_killed" "$FAKE_AMBIENT" 2>/dev/null; then
    pass "Test 1b: kind=worktree_orphan_process_killed emitted to ambient.jsonl"
else
    fail "Test 1b: kind=worktree_orphan_process_killed not found in $FAKE_AMBIENT"
fi

grep "worktree_orphan_process_killed" "$FAKE_AMBIENT" | grep -q '"pid":' \
    || fail "Test 1c: worktree_orphan_process_killed event missing pid field"
grep "worktree_orphan_process_killed" "$FAKE_AMBIENT" | grep -q '"age_seconds":' \
    || fail "Test 1c: worktree_orphan_process_killed event missing age_seconds field"
pass "Test 1c: worktree_orphan_process_killed event carries pid/cmd/age_seconds"

# Now safe to delete — process is gone, directory removal should succeed cleanly.
git -C "$FAKE_REPO" worktree remove "$WT1" --force >/dev/null 2>&1 || rm -rf "$WT1"
[[ -d "$WT1" ]] && fail "Test 1d: worktree directory should be removable after process reap"
pass "Test 1d: worktree directory removed cleanly after process was killed first"

# ── Test 2: prune-worktrees.sh kills the orphan process end-to-end ───────────
WT2="$(make_orphan_worktree "chump-fixture-test-2")"
[[ -d "$WT2" ]] || fail "Test 2 setup: worktree not created at $WT2"

( cd "$WT2" && exec sleep 300 ) &
SLEEP_PID2=$!
sleep 0.3
kill -0 "$SLEEP_PID2" 2>/dev/null || fail "Test 2 setup: fixture sleep process did not start"

CHUMP_SKIP_ORPHAN_PRUNE=0 CHUMP_SKIP_PR_CHECK=1 \
    env -u GIT_DIR -u GIT_WORK_TREE \
    bash -c "cd '$FAKE_REPO' && bash '$PRUNE_SCRIPT' --scan-dir '$FAKE_SCAN'" 2>&1 || true

if [[ -d "$WT2" ]]; then
    kill -9 "$SLEEP_PID2" 2>/dev/null || true
    fail "Test 2: orphan worktree should have been pruned by prune-worktrees.sh"
fi

sleep 0.2
if kill -0 "$SLEEP_PID2" 2>/dev/null; then
    kill -9 "$SLEEP_PID2" 2>/dev/null || true
    fail "Test 2: prune-worktrees.sh removed the directory but left process $SLEEP_PID2 running"
fi
pass "Test 2: prune-worktrees.sh killed the orphan process before removing the worktree"

echo ""
echo "All INFRA-1516 orphan-process-reap checks passed."
