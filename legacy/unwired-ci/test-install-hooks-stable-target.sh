#!/usr/bin/env bash
# scripts/ci/test-install-hooks-stable-target.sh — RESILIENT-075
#
# Guards the fix for the self-destructing-hooks bug: install-hooks.sh symlinked
# every worktree's hooks (including the main repo's shared .git/hooks/) to the
# CURRENT worktree's scripts/git-hooks/. Run from a transient /tmp/chump-<gap>
# claim worktree, that pinned the entire fleet's gate layer to a temp dir that
# vanishes when the claim is reaped — git then silently skips the dangling-symlink
# hooks and ALL gates disappear with no error.
#
# The fix pins the symlink TARGET to the MAIN worktree (always the first entry of
# `git worktree list --porcelain`), with a guard that refuses to anchor hooks
# under /tmp at all.
#
# This test does NOT run the real install-hooks.sh against the live repo (that
# would re-symlink the live .git/hooks/). It (1) statically asserts the fix shape
# and (2) builds an ISOLATED throwaway repo with a linked worktree and proves the
# resolution logic returns the MAIN path even when invoked from the linked one.
set -uo pipefail
ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"; cd "$ROOT" || exit 2
SCRIPT=scripts/setup/install-hooks.sh
P=0; F=0
p(){ echo "[PASS] $1"; P=$((P+1)); }
f(){ echo "[FAIL] $1"; F=$((F+1)); }

echo "=== test-install-hooks-stable-target.sh (RESILIENT-075) ==="

# 1. parses
if bash -n "$SCRIPT" 2>/dev/null; then p "install-hooks.sh parses"; else f "install-hooks.sh FAILS bash -n"; fi

# 2. pins to the main worktree via `git worktree list --porcelain`
if grep -q 'git worktree list --porcelain' "$SCRIPT" && grep -qiE 'MAIN_WORKTREE|main worktree' "$SCRIPT"; then
  p "pins SRC_DIR to the main worktree (worktree-list resolution present)"
else
  f "no main-worktree pinning — SRC_DIR may still follow the current /tmp worktree"
fi

# 3. has the temp-dir refusal guard
if grep -qE '/tmp/\*\|/private/tmp/\*' "$SCRIPT" || grep -qE '/private/tmp' "$SCRIPT"; then
  p "temp-dir guard present (refuses to anchor hooks under /tmp)"
else
  f "no temp-dir guard — could still anchor hooks under a reapable dir"
fi

# 4. bare `git rev-parse --show-toplevel` is no longer the SOLE/primary source
#    (it may remain only as a fallback after MAIN_WORKTREE).
if grep -qE '^REPO_ROOT="\$\(git rev-parse --show-toplevel\)"' "$SCRIPT"; then
  f "primary REPO_ROOT is still bare --show-toplevel (the bug)"
else
  p "primary REPO_ROOT no longer bare --show-toplevel"
fi

# 5. BEHAVIORAL — isolated throwaway repo: prove the resolution picks MAIN even
#    when run from a LINKED worktree. This is the exact awk the script uses.
TMPD="$(mktemp -d 2>/dev/null || echo /tmp/rh075-$$)"
trap 'rm -rf "$TMPD" 2>/dev/null || true' EXIT
(
  set -e
  cd "$TMPD"
  git init -q main_repo
  cd main_repo
  git config user.email t@t; git config user.name t   # local only; throwaway repo
  git commit -q --allow-empty -m init
  MAIN_ABS="$(pwd -P)"
  git worktree add -q ../linked_wt >/dev/null 2>&1
  # From INSIDE the linked worktree, run the script's resolution logic verbatim:
  cd ../linked_wt
  RESOLVED="$(git worktree list --porcelain 2>/dev/null | awk '/^worktree /{print $2; exit}')"
  RESOLVED_ABS="$(cd "$RESOLVED" && pwd -P)"
  CURRENT_ABS="$(pwd -P)"
  echo "    main=$MAIN_ABS  resolved=$RESOLVED_ABS  current(linked)=$CURRENT_ABS"
  [ "$RESOLVED_ABS" = "$MAIN_ABS" ] && [ "$RESOLVED_ABS" != "$CURRENT_ABS" ]
)
if [ $? -eq 0 ]; then
  p "behavioral: from a linked worktree, resolution returns MAIN (not the current worktree)"
else
  f "behavioral: resolution did NOT return the main worktree from a linked one"
fi

echo ""
echo "=== $P passed, $F failed ==="
[ "$P" -ge 1 ] && [ "$F" -eq 0 ] || exit 1
