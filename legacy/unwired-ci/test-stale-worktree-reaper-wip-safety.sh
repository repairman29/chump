#!/usr/bin/env bash
# test-stale-worktree-reaper-wip-safety.sh — RESILIENT-235
#
# Proves the reaper FAILS CLOSED around uncommitted work. Before this fix, the
# RESILIENT-029 WIP guard swallowed git-status errors (2>/dev/null -> uncommitted=0
# -> "nothing to stash") and reaped live WIP whose branch HEAD merely sat on a
# merged BASE commit; a failed stash-push only warned and still reaped. That
# silently destroyed real work (EFFECTIVE-354, EFFECTIVE-361).
#
# Structural checks (contract present in the script):
#   T1: git status exit code captured (status_rc) and refuses reap on non-zero
#   T2: recovery ref verified (rev-parse --verify refs/heads/<wip>) before remove
#   T3: caller skips the destructive remove on a non-zero _wip_stash_work return
#       (emits reason=wip_unsafe_refused_reap)
#   T4: bash -n syntax check passes
#
# Behavioural checks (live reaper against synthetic fixtures):
#   T5: FAIL-CLOSED — a dirty worktree whose HEAD is an ancestor of origin/main but
#       whose gitdir back-ref is corrupted (git status errors, INFRA-779) is NOT
#       removed. (Against the old script it was reaped -> this test fails without
#       the change.)
#   T6: HAPPY PATH — a dirty worktree with a healthy gitdir whose HEAD is an
#       ancestor of origin/main IS reaped, AND its work is preserved on a
#       recoverable wip/ ref (proves the fix didn't just disable reaping).
#
# Run:
#   bash scripts/ci/test-stale-worktree-reaper-wip-safety.sh
# Exits non-zero on any failure.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# Scrub GIT_* env leaked by any pre-push hook before git ops (mirrors sibling test).
[[ -f "$REPO_ROOT/scripts/lib/scrub-git-env.sh" ]] && source "$REPO_ROOT/scripts/lib/scrub-git-env.sh"

REAPER="$REPO_ROOT/scripts/ops/stale-worktree-reaper.sh"
[[ -f "$REAPER" ]] || { echo "[FAIL] reaper not found: $REAPER"; exit 1; }

PASS=0; FAIL=0
ok()   { echo "  [PASS] $*"; PASS=$((PASS+1)); }
fail() { echo "  [FAIL] $*" >&2; FAIL=$((FAIL+1)); }

echo "=== RESILIENT-235: stale-worktree-reaper WIP-safety (fail-closed) ==="

# ── Structural checks ─────────────────────────────────────────────────────────

# T1: status exit code captured + refuse on unreadable.
if grep -q 'status_rc=\$?' "$REAPER" && grep -q 'RESILIENT-235' "$REAPER"; then
    ok "T1: git status exit code captured (fail-closed on unreadable status)"
else
    fail "T1: no status_rc capture — unreadable status can still be misread as clean"
fi

# T2: recovery ref verified before the destructive remove.
if grep -q 'rev-parse --verify --quiet "refs/heads/\$wip_branch"' "$REAPER"; then
    ok "T2: recovery ref verified before remove"
else
    fail "T2: no recovery-ref verification — a failed stash can still lose work"
fi

# T3: caller honors the return code and skips the remove.
if grep -q 'if ! _wip_stash_work' "$REAPER" && grep -q 'wip_unsafe_refused_reap' "$REAPER"; then
    ok "T3: caller skips destructive remove on unsafe return"
else
    fail "T3: caller does not gate the remove on the WIP-guard return code"
fi

# T4: syntax.
if bash -n "$REAPER" 2>/dev/null; then
    ok "T4: bash -n syntax check passes"
else
    fail "T4: bash -n syntax check FAILED"
fi

# ── Behavioural fixture ───────────────────────────────────────────────────────
# A throwaway git universe: bare origin + working clone (acts as REPO_ROOT) with
# an initial commit on main. Worktrees live under $SCAN/chump-* so the reaper's
# scan finds them.
FIX="$(mktemp -d -t r235-wip-safety.XXXXXX)"
# Physical path: macOS mktemp returns /var/folders/... which is a symlink to
# /private/var/...; `git worktree list` reports the physical path, so the reaper's
# CHUMP_WORKTREE_BASE prefix match must use the physical form too.
FIX="$(cd "$FIX" && pwd -P)"
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
# The reaper sources its own libs from $REPO_ROOT/scripts/lib/*; the override points
# REPO_ROOT at this synthetic repo, so symlink the REAL scripts/ tree in so lib
# sourcing resolves while worktree enumeration still finds the fixture worktrees.
ln -s "$REPO_ROOT/scripts" "$REPO/scripts"

# Helper: create a linked worktree at main's HEAD (=> ancestor of origin/main =>
# reapable) with an uncommitted change, aged so no freshness guard trips. Returns
# the path in the global MADE_WT (split `local` decls avoid a macOS bash 3.2
# set -u gotcha where `local a=$1 b=$a` reads b's $a as unbound).
MADE_WT=""
_make_dirty_wt() {
  local name="$1"
  local wt="$SCAN/chump-$name"
  ( cd "$REPO" && git worktree add -q -b "chump/$name-claim" "$wt" main ) >/dev/null 2>&1
  echo "uncommitted change" > "$wt/CHANGED.txt"
  # Age the worktree + its index past any mtime freshness window.
  find "$wt" -exec touch -t 202001010000 {} + 2>/dev/null || true
  MADE_WT="$wt"
}

# Common reaper invocation. Run from inside $REPO so the reaper's cwd-relative git
# calls (merge-base / ls-remote) resolve against the fixture. CHUMP_WORKTREE_BASE
# puts $SCAN in scan scope; CHUMP_REAPER_SAFETY_CHECK=0 + --force-skip-process-check
# disable the UNRELATED guards so only the WIP guard decides fate. Locks come from
# $REPO/.chump-locks (empty in the fixture -> no lease protects the worktrees).
_run_reaper() {
  # SANDBOX: WORKTREE_SCAN_PATHS drops the real /tmp/chump-* glob and
  # CHUMP_RESCUE_SCAN_BASE points the rescue scan at the fixture, so the reaper
  # can NEVER touch real worktrees on this machine. The fixture worktrees are still
  # found via the git-worktree-list pass (they are worktrees of $REPO) + CHUMP_WORKTREE_BASE.
  ( cd "$REPO" && \
    CHUMP_REPO_ROOT_OVERRIDE="$REPO" \
    CHUMP_WORKTREE_BASE="$SCAN" \
    WORKTREE_SCAN_PATHS=".claude/worktrees" \
    CHUMP_RESCUE_SCAN_BASE="$SCAN" \
    CHUMP_REAPER_SAFETY_CHECK=0 \
    bash "$REAPER" --execute --force-skip-process-check --age-min 0 ) >/dev/null 2>&1 || true
}

# T5: FAIL-CLOSED — corrupted gitdir back-ref (git status errors) must NOT be reaped.
_make_dirty_wt r235corrupt; WT5="$MADE_WT"
# Corrupt the worktree's .git pointer so `git -C $WT5 status` fails (INFRA-779 shape).
echo "gitdir: /nonexistent/r235/bogus" > "$WT5/.git"
_run_reaper
if [[ -d "$WT5" ]]; then
    ok "T5: dirty worktree with unreadable git status was REFUSED (not destroyed)"
else
    fail "T5: dirty worktree with unreadable git status was REAPED — WIP destroyed (fail-open)"
fi

# T6: HAPPY PATH — healthy dirty worktree IS reaped AND work preserved on a wip/ ref.
_make_dirty_wt r235happy; WT6="$MADE_WT"
_run_reaper
_wip_ref="$(git -C "$REPO" for-each-ref --format='%(refname:short)' 'refs/heads/wip/*' 2>/dev/null | head -1)"
_wip_remote="$(git -C "$REPO" ls-remote --heads origin 'wip/*' 2>/dev/null | head -1)"
if [[ ! -d "$WT6" ]] && { [[ -n "$_wip_ref" ]] || [[ -n "$_wip_remote" ]]; }; then
    ok "T6: healthy dirty worktree reaped AND work preserved on a recoverable wip/ ref"
elif [[ -d "$WT6" ]]; then
    fail "T6: healthy dirty worktree was NOT reaped (fix over-blocks the happy path)"
else
    fail "T6: healthy dirty worktree reaped but NO wip/ recovery ref exists (work lost)"
fi

echo ""
echo "=== RESILIENT-235 WIP-safety: PASS=$PASS FAIL=$FAIL ==="
[[ $FAIL -eq 0 ]] || exit 1
