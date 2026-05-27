#!/usr/bin/env bash
# test-stale-worktree-reaper-stash.sh — RESILIENT-029
#
# Verifies that stale-worktree-reaper.sh stashes uncommitted/unpushed work to
# a wip/ branch before reaping, rather than silently destroying it.
#
# Tests:
#   T1: clean worktree (no uncommitted, no unpushed) → reaped normally, no wip branch
#   T2: worktree with uncommitted changes → wip/<gap>-<ts> branch created, ambient
#       event emitted, then worktree reaped
#   T3: worktree with unpushed commits → wip/<gap>-<ts> branch with the commits
#       pushed, ambient event emitted, then reaped
#   T4: worktree with both uncommitted + unpushed → both preserved in wip branch,
#       then reaped
#
# Uses a file:// local git remote — no GitHub hits.
#
# Run:
#   ./scripts/ci/test-stale-worktree-reaper-stash.sh
# Exits non-zero on any failure.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REAL_REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
REAPER="$REAL_REPO_ROOT/scripts/ops/stale-worktree-reaper.sh"

[[ -x "$REAPER" ]] || { echo "FAIL: reaper not executable: $REAPER"; exit 1; }

PASS=0
FAIL=0
ok()   { echo "  PASS: $*"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $*" >&2; FAIL=$((FAIL+1)); }

echo "=== RESILIENT-029: stale-worktree-reaper wip-stash tests ==="

# ── Scaffold: self-contained fake repo hierarchy ──────────────────────────────
TMPBASE=$(mktemp -d)
trap 'rm -rf "$TMPBASE"' EXIT

FAKE_ORIGIN="$TMPBASE/origin.git"          # bare "remote"
FAKE_REPO="$TMPBASE/repo"                  # simulated Chump repo root
LOCKS_DIR="$FAKE_REPO/.chump-locks"
AMBIENT="$LOCKS_DIR/ambient.jsonl"
ARCHIVE_DIR="$FAKE_REPO/docs/archive/eval-runs"
WT_BASE="$FAKE_REPO/.claude/worktrees"

mkdir -p "$FAKE_ORIGIN" "$LOCKS_DIR" "$ARCHIVE_DIR" "$WT_BASE"
touch "$AMBIENT"

# Stub out the lib files the reaper sources.  They use functions that are
# called on every run; we replace them with no-ops so the reaper stays
# fully self-contained against our fake repo.
mkdir -p "$FAKE_REPO/scripts/lib"

cat > "$FAKE_REPO/scripts/lib/reaper-instrumentation.sh" <<'LIB'
reaper_setup()             { REAPER_LOCK_DIR="${LOCKS_DIR:-/tmp}"; }
reaper_check_disk_headroom() { :; }
reaper_rotate_log()        { :; }
reaper_finish()            { :; }
LIB

cat > "$FAKE_REPO/scripts/lib/lease.sh" <<'LIB'
lease_iter()       { true; }
lease_worktree()   { echo ""; }
lease_is_fresh()   { return 1; }
lease_heartbeat_age_s() { echo 9999; }
LIB

cat > "$FAKE_REPO/scripts/lib/worktree-iter.sh" <<'LIB'
emit_reaper_event() {
    local kind="$1" wt_path="$2" reason="${3:-}" extra="${4:-}"
    printf '{"ts":"%s","kind":"%s","worktree":"%s","reason":"%s"%s}\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$kind" "$wt_path" "$reason" \
        "${extra:+,$extra}" \
        >> "${LOCKS_DIR}/ambient.jsonl" 2>/dev/null || true
}
LIB

# Bare origin.
git init --bare "$FAKE_ORIGIN" -b main >/dev/null 2>&1

# Init FAKE_REPO directly (cloning an empty bare repo exits non-zero on some git).
git init -b main "$FAKE_REPO" >/dev/null 2>&1
git -C "$FAKE_REPO" remote add origin "file://$FAKE_ORIGIN"
git -C "$FAKE_REPO" config user.email "test@test.local"
git -C "$FAKE_REPO" config user.name "Test"

# Seed main with an initial commit so HEAD exists.
echo "init" > "$FAKE_REPO/README"
git -C "$FAKE_REPO" add README
git -C "$FAKE_REPO" commit -m "init" >/dev/null 2>&1
git -C "$FAKE_REPO" push -u origin main >/dev/null 2>&1

# Helper: create a linked worktree from a branch that has "merged" into main.
# The branch tip is an ancestor of origin/main — reapable by merge-ancestor check.
# Args: <branch-name>  →  sets WT path to $WT_BASE/<branch-name>
make_merged_worktree() {
    local branch="$1"
    local wt="$WT_BASE/$branch"
    mkdir -p "$WT_BASE"
    git -C "$FAKE_REPO" checkout -b "$branch" >/dev/null 2>&1
    echo "work-$branch" > "$FAKE_REPO/work-$branch.txt"
    git -C "$FAKE_REPO" add "work-$branch.txt"
    git -C "$FAKE_REPO" commit -m "work on $branch" >/dev/null 2>&1
    git -C "$FAKE_REPO" push origin "$branch" >/dev/null 2>&1
    # Merge branch into main (simulates a merged PR).
    git -C "$FAKE_REPO" checkout main >/dev/null 2>&1
    git -C "$FAKE_REPO" merge --ff-only "$branch" >/dev/null 2>&1
    git -C "$FAKE_REPO" push origin main >/dev/null 2>&1
    # Create linked worktree pointing at the now-merged branch.
    git -C "$FAKE_REPO" worktree add "$wt" "$branch" >/dev/null 2>&1
    git -C "$wt" config user.email "test@test.local"
    git -C "$wt" config user.name "Test"
    echo "$wt"
}

# Run the reaper against FAKE_REPO with full env isolation.
# WORKTREE_SCAN_PATHS is scoped to just the fake WT base so the reaper never
# touches /tmp/chump-* worktrees from the real fleet running alongside CI.
run_reaper() {
    CHUMP_SKIP_INSTRUMENTATION=1 \
    CHUMP_REAPER_SAFETY_CHECK=0 \
    CHUMP_REPO_ROOT_OVERRIDE="$FAKE_REPO" \
    CHUMP_WORKTREE_BASE="$WT_BASE" \
    WORKTREE_SCAN_PATHS="$WT_BASE" \
    REMOTE=origin \
    BASE=main \
    LOCKS_DIR="$LOCKS_DIR" \
    REAPER_LOCK_DIR="$LOCKS_DIR" \
        bash "$REAPER" \
            --execute \
            --age-min 0 \
            --force-skip-process-check \
        2>/dev/null
}

# ─── T1: clean worktree → reaped normally, no wip branch ────────────────────
echo ""
echo "T1: clean worktree → reaped normally, no wip branch"
WT1=$(make_merged_worktree "t1-clean")

run_reaper || true

if [[ ! -d "$WT1" ]]; then
    ok "T1: clean worktree was reaped"
else
    fail "T1: clean worktree was NOT reaped (still at $WT1)"
fi

if ! git -C "$FAKE_REPO" ls-remote --heads origin 'wip/t1*' 2>/dev/null | grep -q .; then
    ok "T1: no wip branch created for clean worktree"
else
    fail "T1: unexpected wip branch created for clean worktree"
fi

if ! grep -q 'worktree_work_stashed_before_reap' "$AMBIENT" 2>/dev/null; then
    ok "T1: no stash ambient event for clean worktree"
else
    # Accept only if the event is clearly not for t1-clean.
    if grep 'worktree_work_stashed_before_reap' "$AMBIENT" | grep -q 't1'; then
        fail "T1: stash event incorrectly references t1-clean"
    else
        ok "T1: stash event is not for t1-clean"
    fi
fi
truncate -s 0 "$AMBIENT"

# ─── T2: uncommitted changes → wip branch created, event emitted, reaped ───
echo ""
echo "T2: worktree with uncommitted changes → wip branch + event"
WT2=$(make_merged_worktree "t2-uncommitted")
# Drop a staged (uncommitted) file.
echo "uncommitted work" > "$WT2/uncommitted.txt"
git -C "$WT2" add uncommitted.txt

run_reaper || true

if [[ ! -d "$WT2" ]]; then
    ok "T2: worktree with uncommitted changes was reaped"
else
    fail "T2: worktree with uncommitted changes was NOT reaped"
fi

WIP_T2=$(git -C "$FAKE_REPO" ls-remote --heads origin 'wip/*' 2>/dev/null \
    | awk '{print $2}' | sed 's|refs/heads/||' | head -1 || true)
if [[ -n "$WIP_T2" ]]; then
    ok "T2: wip branch created: $WIP_T2"
else
    fail "T2: no wip branch found on origin after uncommitted-change reap"
fi

if grep -q 'worktree_work_stashed_before_reap' "$AMBIENT" 2>/dev/null; then
    ok "T2: worktree_work_stashed_before_reap event emitted"
    if grep 'worktree_work_stashed_before_reap' "$AMBIENT" | grep -q '"uncommitted_lines"'; then
        ok "T2: event contains uncommitted_lines field"
    else
        fail "T2: event missing uncommitted_lines field"
    fi
else
    fail "T2: worktree_work_stashed_before_reap event NOT emitted"
fi
truncate -s 0 "$AMBIENT"
# Clean up wip branches for T3/T4 isolation.
for _ref in $(git -C "$FAKE_REPO" ls-remote --heads origin 'wip/*' 2>/dev/null | awk '{print $2}' | sed 's|refs/heads/||'); do
    git -C "$FAKE_REPO" push origin --delete "$_ref" >/dev/null 2>&1 || true
done

# ─── T3: unpushed commits → wip branch with commits pushed, event emitted ──
echo ""
echo "T3: worktree with unpushed commits → wip branch preserves them"
WT3=$(make_merged_worktree "t3-unpushed")
# Simulate the scenario: origin branch was deleted (PR auto-cleanup after merge),
# then agent added a commit locally that was never pushed.  The reaper sees
# remote_exists=0 → reapable.  But there is a local commit ahead that must
# be preserved before removal.
git -C "$FAKE_REPO" push origin --delete t3-unpushed >/dev/null 2>&1 || true
# Now add an unpushed commit in the worktree on top.
echo "unpushed work" > "$WT3/unpushed.txt"
git -C "$WT3" add unpushed.txt
git -C "$WT3" commit -m "unpushed commit" --no-verify >/dev/null 2>&1

run_reaper || true

if [[ ! -d "$WT3" ]]; then
    ok "T3: worktree with unpushed commits was reaped"
else
    fail "T3: worktree with unpushed commits was NOT reaped"
fi

WIP_T3=$(git -C "$FAKE_REPO" ls-remote --heads origin 'wip/*' 2>/dev/null \
    | awk '{print $2}' | sed 's|refs/heads/||' | head -1 || true)
if [[ -n "$WIP_T3" ]]; then
    ok "T3: wip branch created: $WIP_T3"
else
    fail "T3: no wip branch found on origin after unpushed-commit reap"
fi

if grep -q 'worktree_work_stashed_before_reap' "$AMBIENT" 2>/dev/null; then
    ok "T3: worktree_work_stashed_before_reap event emitted"
    if grep 'worktree_work_stashed_before_reap' "$AMBIENT" | grep -q '"unpushed_commits"'; then
        ok "T3: event contains unpushed_commits field"
    else
        fail "T3: event missing unpushed_commits field"
    fi
else
    fail "T3: worktree_work_stashed_before_reap event NOT emitted"
fi
truncate -s 0 "$AMBIENT"
for _ref in $(git -C "$FAKE_REPO" ls-remote --heads origin 'wip/*' 2>/dev/null | awk '{print $2}' | sed 's|refs/heads/||'); do
    git -C "$FAKE_REPO" push origin --delete "$_ref" >/dev/null 2>&1 || true
done

# ─── T4: both uncommitted + unpushed → all preserved, then reaped ───────────
echo ""
echo "T4: worktree with both uncommitted + unpushed → all preserved in wip branch"
WT4=$(make_merged_worktree "t4-both")
# Delete remote branch so reaper sees remote_exists=0 → reapable.
git -C "$FAKE_REPO" push origin --delete t4-both >/dev/null 2>&1 || true
# Unpushed commit on top.
echo "unpushed work" > "$WT4/unpushed2.txt"
git -C "$WT4" add unpushed2.txt
git -C "$WT4" commit -m "unpushed work" --no-verify >/dev/null 2>&1
# Plus staged (uncommitted) change on top.
echo "also uncommitted" > "$WT4/also-uncommitted.txt"
git -C "$WT4" add also-uncommitted.txt

run_reaper || true

if [[ ! -d "$WT4" ]]; then
    ok "T4: worktree with both changes was reaped"
else
    fail "T4: worktree with both changes was NOT reaped"
fi

WIP_T4=$(git -C "$FAKE_REPO" ls-remote --heads origin 'wip/*' 2>/dev/null \
    | awk '{print $2}' | sed 's|refs/heads/||' | head -1 || true)
if [[ -n "$WIP_T4" ]]; then
    ok "T4: wip branch created: $WIP_T4"
else
    fail "T4: no wip branch found on origin after both-changes reap"
fi

if grep -q 'worktree_work_stashed_before_reap' "$AMBIENT" 2>/dev/null; then
    ok "T4: worktree_work_stashed_before_reap event emitted"
    EVENT_LINE=$(grep 'worktree_work_stashed_before_reap' "$AMBIENT" | tail -1)
    if echo "$EVENT_LINE" | grep -q '"uncommitted_lines"' \
       && echo "$EVENT_LINE" | grep -q '"unpushed_commits"'; then
        ok "T4: event contains both uncommitted_lines and unpushed_commits fields"
    else
        fail "T4: event missing one or more required fields (got: $EVENT_LINE)"
    fi
else
    fail "T4: worktree_work_stashed_before_reap event NOT emitted"
fi

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
if [[ $FAIL -gt 0 ]]; then
    echo "FAIL: $FAIL test(s) failed" >&2
    exit 1
fi
echo "PASS: all RESILIENT-029 stash tests"
exit 0
