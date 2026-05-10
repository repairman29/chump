#!/usr/bin/env bash
# fix-worktree-show-toplevel.sh — INFRA-810
#
# Fixes the "this operation must be run in a work tree" error that affects
# all linked worktrees when the main .git/config has core.bare=true.
#
# Root cause: git/go-git sometimes writes core.bare=true when adding the
# first linked worktree, even though the repo is not bare. When extensions.
# worktreeconfig=true is set, each linked worktree can override this via a
# per-worktree config.worktree file. Without that override, every call to
# `git rev-parse --show-toplevel` inside a linked worktree fails.
#
# Fix: write [core] bare=false to $GIT_DIR/config.worktree for every linked
# worktree's gitdir (and for the main worktree if it lacks one). This
# overrides the global core.bare=true just for that worktree.
#
# Idempotent: safe to run multiple times.
#
# Usage:
#   scripts/setup/fix-worktree-show-toplevel.sh
#   scripts/setup/fix-worktree-show-toplevel.sh --check   # exit 1 if fix needed
#
# Exit codes:
#   0  — all worktrees healthy (or fixed)
#   1  — --check mode and fix was needed (unfixed)

set -euo pipefail

CHECK_ONLY=0
[[ "${1:-}" == "--check" ]] && CHECK_ONLY=1

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
GIT_COMMON="$(git rev-parse --git-common-dir 2>/dev/null || echo ".git")"
if [[ "$GIT_COMMON" == ".git" ]]; then
    GIT_COMMON="$REPO_ROOT/.git"
elif [[ ! "$GIT_COMMON" = /* ]]; then
    GIT_COMMON="$(cd "$GIT_COMMON" && pwd)"
fi

WORKTREE_CONFIG_CONTENT='[core]
	bare = false
'

fixed=0
checked=0

fix_worktree_gitdir() {
    local gitdir="$1"
    local config_wt="$gitdir/config.worktree"
    checked=$((checked + 1))

    if [[ -f "$config_wt" ]] && grep -q "bare = false" "$config_wt" 2>/dev/null; then
        return 0  # already fixed
    fi

    if [[ "$CHECK_ONLY" == "1" ]]; then
        echo "[fix-worktree] NEEDS FIX: $gitdir" >&2
        fixed=$((fixed + 1))
        return 0
    fi

    printf '%s' "$WORKTREE_CONFIG_CONTENT" > "$config_wt"
    echo "[fix-worktree] wrote config.worktree → $config_wt"
    fixed=$((fixed + 1))
}

# Fix main worktree gitdir
fix_worktree_gitdir "$GIT_COMMON"

# Fix all linked worktrees
if [[ -d "$GIT_COMMON/worktrees" ]]; then
    for wt_gitdir in "$GIT_COMMON/worktrees"/*/; do
        [[ -d "$wt_gitdir" ]] || continue
        fix_worktree_gitdir "$wt_gitdir"
    done
fi

# Run git worktree repair to heal any stale .git pointers while we're here
if [[ "$CHECK_ONLY" != "1" ]] && command -v git >/dev/null; then
    git worktree repair 2>/dev/null || true
fi

if [[ "$CHECK_ONLY" == "1" ]]; then
    if [[ $fixed -gt 0 ]]; then
        echo "[fix-worktree] $fixed of $checked worktree(s) need config.worktree fix" >&2
        echo "[fix-worktree] Run: scripts/setup/fix-worktree-show-toplevel.sh" >&2
        exit 1
    else
        echo "[fix-worktree] OK: all $checked worktree(s) have config.worktree"
    fi
else
    if [[ $fixed -gt 0 ]]; then
        echo "[fix-worktree] Fixed $fixed of $checked worktree(s)"
        echo "[fix-worktree] git rev-parse --show-toplevel should now work in all linked worktrees"
    else
        echo "[fix-worktree] OK: all $checked worktree(s) already have config.worktree"
    fi
fi
