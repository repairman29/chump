#!/usr/bin/env bash
#
# One-shot installer for Chump's git hooks. Installs into every git worktree
# (main + linked) so parallel agents in `.claude/worktrees/` are protected
# from cargo-fmt drift even when their working-tree branch doesn't have the
# hook source file checked out.
#
# Why per-worktree (not core.hooksPath): linked git worktrees have their own
# `.git/worktrees/<name>/hooks/` dir. core.hooksPath is shared across
# worktrees but resolved against the WORKING tree, so worktrees on stale
# branches that don't have scripts/git-hooks/ checked out would see no hooks.
# Per-worktree symlinks pointing at an absolute path Just Work everywhere.
#
# Run once after cloning. Idempotent — safe to re-run any time, especially
# after `git worktree add`.

set -euo pipefail

# --quiet suppresses per-worktree install lines; errors still go to stderr.
QUIET=0
for arg in "$@"; do
    [[ "$arg" == "--quiet" ]] && QUIET=1
done
log() { [[ "$QUIET" == "0" ]] && echo "$@" || true; }

REPO_ROOT="$(git rev-parse --show-toplevel)"
SRC_DIR="$REPO_ROOT/scripts/git-hooks"

if [ ! -d "$SRC_DIR" ]; then
    echo "error: $SRC_DIR not found" >&2
    exit 1
fi

# Make every hook executable (forgetting chmod is the #1 install bug).
hook_count=0
for src in "$SRC_DIR"/*; do
    [ -f "$src" ] || continue
    chmod +x "$src"
    hook_count=$((hook_count + 1))
done

# Resolve hooks dir for each worktree from `git worktree list --porcelain`.
# Main worktree gets `.git/hooks/`; linked worktrees get
# `.git/worktrees/<name>/hooks/`. We use absolute paths in symlinks so the
# target resolves regardless of which dir the user is in when they commit.
worktree_count=0
while read -r line; do
    case "$line" in
        worktree\ *)
            wt_path="${line#worktree }"
            # Find its git dir.
            wt_gitdir=$(git -C "$wt_path" rev-parse --absolute-git-dir 2>/dev/null || true)
            if [ -z "$wt_gitdir" ]; then
                continue
            fi
            mkdir -p "$wt_gitdir/hooks"
            for src in "$SRC_DIR"/*; do
                [ -f "$src" ] || continue
                name=$(basename "$src")
                ln -sf "$src" "$wt_gitdir/hooks/$name"
            done
            log "installed: $wt_gitdir/hooks/* -> $SRC_DIR/*"
            worktree_count=$((worktree_count + 1))
            ;;
    esac
done < <(git worktree list --porcelain)

log ""
log "Installed $hook_count hook(s) into $worktree_count worktree(s)."
log "Re-run after every \`git worktree add\` to cover the new worktree."
log "Skip a hook for one commit: git commit --no-verify"
