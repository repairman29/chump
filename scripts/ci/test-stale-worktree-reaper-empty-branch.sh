#!/usr/bin/env bash
# test-stale-worktree-reaper-empty-branch.sh — RESILIENT-263
#
# Proves the reaper does not mistake "never started" for "already merged".
#
# `git worktree add /tmp/chump-x -b new-branch main` creates a branch with ZERO
# commits. By ancestry that branch IS an ancestor of origin/main, so the
# reapability test
#
#     git merge-base --is-ancestor "$wt_branch" "$REMOTE/$BASE"
#
# returned true and the worktree was reaped as "branch merged into origin/main"
# — for work that had never been merged because it had never existed. Live on
# 2026-08-09: /tmp/chump-r246 was created at ~16:09 and deleted at 16:44:48
# while a session was editing in it (.chump-locks/ambient.jsonl,
# kind=worktree_reaped, reason="branch merged into origin/main").
#
# EVERY new worktree was exposed in the window between `worktree add` and its
# first commit — the exact window in which an agent explores before committing.
#
# Second defect, same incident: the rescue branch was named from
# `ls claim-*.json | head -1`, whichever claim file happened to sort first, with
# no connection to the worktree being reaped. r246's work was stashed onto
# wip/resilient-262-<ts>. A rescue nobody can find is not a rescue.
#
# Structural checks (contract present in the script):
#   T1: the empty-branch guard exists and is consulted by the merged test
#   T2: a new-worktree grace window exists
#   T3: rescue-branch attribution is derived from THIS worktree, not `head -1`
#   T4: bash -n syntax check passes
#
# Behavioural checks (live reaper against synthetic fixtures):
#   T5: a FRESH worktree on a zero-commit branch is NOT reaped
#   T6: an AGED worktree on a zero-commit branch is still NOT reaped — proves the
#       semantic fix carries it, not just the clock
#   T7: HAPPY PATH — a worktree whose branch really did commit and merge IS still
#       reaped (proves the fix did not simply disable reaping)
#   T8: the rescue branch is named after the reaped worktree's own gap even when
#       an unrelated claim file sorts first
#
# Run:
#   bash scripts/ci/test-stale-worktree-reaper-empty-branch.sh
# Exits non-zero on any failure.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
[[ -f "$REPO_ROOT/scripts/lib/scrub-git-env.sh" ]] && source "$REPO_ROOT/scripts/lib/scrub-git-env.sh"

REAPER="$REPO_ROOT/scripts/ops/stale-worktree-reaper.sh"
[[ -f "$REAPER" ]] || { echo "[FAIL] reaper not found: $REAPER"; exit 1; }

PASS=0; FAIL=0
ok()   { echo "  [PASS] $*"; PASS=$((PASS+1)); }
fail() { echo "  [FAIL] $*" >&2; FAIL=$((FAIL+1)); }

echo "=== RESILIENT-263: reaper must not treat an empty branch as merged ==="

# ── Structural checks ─────────────────────────────────────────────────────────

if grep -q 'branch_has_own_commits' "$REAPER"; then
    ok "T1: empty-branch guard present and wired into the merged test"
else
    fail "T1: no branch_has_own_commits guard — a zero-commit branch still reads as merged"
fi

if grep -q 'NEW_WORKTREE_GRACE_MIN' "$REAPER" && grep -q 'worktree_within_grace' "$REAPER"; then
    ok "T2: new-worktree grace window present"
else
    fail "T2: no grace window — a worktree can be reaped seconds after creation"
fi

# The bug was `ls "$LOCKS_DIR/claim-"*.json | head -1`. Attribution must instead
# be tied to the worktree under consideration.
if grep -q 'grep -qF "\$wt" "\$claim_file"' "$REAPER"; then
    ok "T3: rescue-branch attribution matches the claim file against THIS worktree"
else
    fail "T3: attribution still picks an arbitrary claim file — rescue branches get the wrong gap id"
fi

if bash -n "$REAPER" 2>/dev/null; then
    ok "T4: bash -n syntax check passes"
else
    fail "T4: bash -n syntax check FAILED"
fi

# ── Behavioural fixture ───────────────────────────────────────────────────────
FIX="$(mktemp -d -t r263-empty-branch.XXXXXX)"
FIX="$(cd "$FIX" && pwd -P)"   # macOS /var -> /private/var; git reports physical
SCAN="$FIX/scan"
mkdir -p "$SCAN"
cleanup() { rm -rf "$FIX" 2>/dev/null || true; }
trap cleanup EXIT

git init --bare -q "$FIX/origin.git"
git clone -q "$FIX/origin.git" "$FIX/repo"
(
  cd "$FIX/repo"
  git config user.email t@t.t; git config user.name t
  echo base > base.txt; git add base.txt
  git commit -q -m "base"; git branch -M main; git push -q origin main
)
REPO="$FIX/repo"
ln -s "$REPO_ROOT/scripts" "$REPO/scripts"
mkdir -p "$REPO/.chump-locks"

# A worktree on a BRAND-NEW branch: zero commits, dirty. This is the shape that
# was being destroyed.
_make_empty_branch_wt() {
  local name="$1" age="$2"   # age=old -> push mtimes back past every freshness window
  local wt="$SCAN/chump-$name"
  ( cd "$REPO" && git worktree add -q -b "$name" "$wt" main ) >/dev/null 2>&1
  echo "work in progress" > "$wt/WIP.txt"
  if [[ "$age" == "old" ]]; then
    find "$wt" -exec touch -t 202001010000 {} + 2>/dev/null || true
  fi
  MADE_WT="$wt"
}

_run_reaper() {
  # Sandboxed exactly like the sibling tests: the real /tmp/chump-* glob is
  # dropped and the rescue scan is pointed at the fixture, so this can never
  # touch a real worktree on this machine.
  ( cd "$REPO" && \
    CHUMP_REPO_ROOT_OVERRIDE="$REPO" \
    CHUMP_WORKTREE_BASE="$SCAN" \
    WORKTREE_SCAN_PATHS=".claude/worktrees" \
    CHUMP_RESCUE_SCAN_BASE="$SCAN" \
    CHUMP_REAPER_SAFETY_CHECK=0 \
    bash "$REAPER" --execute --force-skip-process-check --age-min 0 ) >/dev/null 2>&1 || true
}

# T5: a fresh zero-commit worktree survives. Against the old script this is the
# /tmp/chump-r246 incident reproduced exactly.
_make_empty_branch_wt resilient-263-fresh new; WT5="$MADE_WT"
_run_reaper
if [[ -d "$WT5" ]]; then
    ok "T5: FRESH worktree on a zero-commit branch was NOT reaped"
else
    fail "T5: FRESH worktree on a zero-commit branch was REAPED — the r246 incident reproduces"
fi

# T6: the same shape, aged past every mtime window. If only the grace clock were
# doing the work this would be destroyed; the semantic guard has to carry it.
_make_empty_branch_wt resilient-263-aged old; WT6="$MADE_WT"
_run_reaper
if [[ -d "$WT6" ]]; then
    ok "T6: AGED worktree on a zero-commit branch was NOT reaped (semantic guard, not just the clock)"
else
    fail "T6: AGED zero-commit worktree was REAPED — the guard is only a timer, not a fix"
fi

# T7: a branch that genuinely committed and merged must STILL be reaped, or the
# fix has simply turned the reaper off.
WT7="$SCAN/chump-resilient-263-merged"
( cd "$REPO" && git worktree add -q -b resilient-263-merged "$WT7" main ) >/dev/null 2>&1
(
  cd "$WT7"
  git config user.email t@t.t; git config user.name t
  echo real > REAL.txt; git add REAL.txt
  git commit -q -m "resilient-263: a real commit"
)
# Land it on origin/main so the branch is genuinely merged, then refresh the
# remote-tracking ref the reaper compares against.
( cd "$REPO" && git merge -q --no-edit resilient-263-merged >/dev/null 2>&1 && git push -q origin main ) || true
( cd "$REPO" && git fetch -q origin ) || true
find "$WT7" -exec touch -t 202001010000 {} + 2>/dev/null || true
_run_reaper
if [[ ! -d "$WT7" ]]; then
    ok "T7: a genuinely merged branch's worktree IS still reaped (reaping not disabled)"
else
    fail "T7: a genuinely merged worktree was NOT reaped — the fix over-blocks"
fi

# T8: attribution. Plant a claim file for an UNRELATED gap that sorts first, then
# reap a dirty worktree belonging to a different one. The rescue branch must be
# named for the worktree that was reaped.
WT8="$SCAN/chump-resilient-264-attrib"
( cd "$REPO" && git worktree add -q -b resilient-264-attrib "$WT8" main ) >/dev/null 2>&1
(
  cd "$WT8"
  git config user.email t@t.t; git config user.name t
  echo attrib > A.txt; git add A.txt
  git commit -q -m "resilient-264: attributable commit"
)
( cd "$REPO" && git merge -q --no-edit resilient-264-attrib >/dev/null 2>&1 && git push -q origin main ) || true
( cd "$REPO" && git fetch -q origin ) || true
echo "dirty" > "$WT8/DIRTY.txt"      # force the stash path
# 'claim-aaa' sorts before anything else and names a DIFFERENT worktree.
printf '{"gap_id":"UNRELATED-999","worktree":"%s"}\n' "$SCAN/chump-somewhere-else" \
    > "$REPO/.chump-locks/claim-aaa-unrelated.json"
find "$WT8" -exec touch -t 202001010000 {} + 2>/dev/null || true
_run_reaper
_wip_refs="$(git -C "$REPO" for-each-ref --format='%(refname:short)' 'refs/heads/wip/*' 2>/dev/null || true)"
# The rescue branch is named for the GAP (resilient-264), not the full branch
# name (resilient-264-attrib) — that is correct: wip/<gap>-<ts> is the contract.
if printf '%s' "$_wip_refs" | grep -qi 'wip/resilient-264-'; then
    ok "T8: rescue branch is named for the reaped worktree's gap, not the first claim file"
elif printf '%s' "$_wip_refs" | grep -qi 'unrelated-999'; then
    fail "T8: rescue branch took an unrelated claim file's gap id (the r246/r262 mislabel)"
elif [[ -z "$_wip_refs" ]]; then
    fail "T8: no wip/ rescue ref was created at all (refs: none)"
else
    fail "T8: rescue branch named unexpectedly: $_wip_refs"
fi

echo ""
echo "=== RESILIENT-263 empty-branch safety: PASS=$PASS FAIL=$FAIL ==="
[[ $FAIL -eq 0 ]] || exit 1
