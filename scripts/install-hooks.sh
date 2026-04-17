#!/usr/bin/env bash
#
# One-shot installer for Chump's git hooks. Symlinks each hook from
# scripts/git-hooks/ into .git/hooks/ so they survive `git pull` and stay
# in sync with the tracked source.
#
# Run once after cloning. Idempotent — safe to re-run.

set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
SRC_DIR="$REPO_ROOT/scripts/git-hooks"
DST_DIR="$REPO_ROOT/.git/hooks"

if [ ! -d "$SRC_DIR" ]; then
    echo "error: $SRC_DIR not found" >&2
    exit 1
fi

mkdir -p "$DST_DIR"

count=0
for src in "$SRC_DIR"/*; do
    [ -f "$src" ] || continue
    name=$(basename "$src")
    dst="$DST_DIR/$name"
    # Make sure source is executable (forgetting chmod is the #1 install bug).
    chmod +x "$src"
    # Use a relative symlink so checking it into a worktree clone Just Works.
    ln -sf "../../scripts/git-hooks/$name" "$dst"
    echo "installed: .git/hooks/$name -> scripts/git-hooks/$name"
    count=$((count + 1))
done

echo ""
echo "Installed $count hook(s). Skip a hook for one commit with: git commit --no-verify"
