#!/usr/bin/env bash
# repair-main-worktree-config.sh — INFRA-1060 (2026-05-13)
#
# Detect and remove stray core.worktree from the MAIN repo's .git/config.
#
# The bug: when a worktree creation race or another agent's git operation
# accidentally runs 'git config core.worktree <path>' in the main checkout
# context, the main .git/config acquires a [core] worktree= line that
# misdirects all git operations (gap YAML writes, 'git status', etc.) to a
# /tmp/chump-* sibling worktree path.
#
# This script detects and removes that stray key.  Safe to run repeatedly
# (idempotent: exits 0 with no output if config is already clean).
#
# Usage:
#   scripts/ops/repair-main-worktree-config.sh [--check]
#   scripts/ops/repair-main-worktree-config.sh [--check] [--json]
#
#   --check   Detect only; exit 1 if corrupt, 0 if clean.  No writes.
#   --json    Emit machine-readable status line.
#
# Called by:
#   - Pre-commit hook (detect, refuse commit)   # INFRA-1060 AC4
#   - scripts/coord/gap-claim.sh (post-worktree-add sanitization)
#   - operator on demand after seeing wrong YAML paths
#
# Root-cause notes (AC1):
#   The precise trigger is not fully isolated, but the check-worktree-config.sh
#   --fix path is a candidate: if a linked worktree's .git file was corrupted
#   by an INFRA-779 race (pointing at the main .git instead of
#   .git/worktrees/<name>/), then 'git --git-dir=<main .git> config
#   core.worktree <path>' would write to the main config.  'git worktree add'
#   and 'git worktree repair' in clean conditions do NOT write core.worktree.

set -euo pipefail

CHECK_ONLY=0
JSON_OUT=0
for arg in "$@"; do
    case "$arg" in
        --check) CHECK_ONLY=1 ;;
        --json)  JSON_OUT=1 ;;
    esac
done

# Resolve the main repo's git dir.
# Prefer REPO_ROOT env (set by callers that know the repo path).
# Fall back to git rev-parse from CWD.
if [[ -n "${REPO_ROOT:-}" && -d "${REPO_ROOT}/.git" ]]; then
    MAIN_GIT_DIR="${REPO_ROOT}/.git"
else
    MAIN_GIT_DIR="$(git rev-parse --git-common-dir 2>/dev/null || echo "")"
fi

if [[ -z "$MAIN_GIT_DIR" || ! -d "$MAIN_GIT_DIR" ]]; then
    if [[ "$JSON_OUT" == "1" ]]; then
        echo '{"status":"error","message":"not inside a git repo"}'
    else
        echo "[repair-main-worktree-config] ERROR: not inside a git repo" >&2
    fi
    exit 2
fi

# Read current core.worktree from the MAIN .git/config (not a worktree's config).
CURRENT_VAL="$(git --git-dir="$MAIN_GIT_DIR" config --local core.worktree 2>/dev/null || echo "")"

if [[ -z "$CURRENT_VAL" ]]; then
    # Clean — nothing to do.
    if [[ "$JSON_OUT" == "1" ]]; then
        echo '{"status":"ok","core_worktree":null}'
    fi
    exit 0
fi

# Stray core.worktree detected.
if [[ "$JSON_OUT" == "1" ]]; then
    printf '{"status":"%s","core_worktree":"%s"}\n' \
        "$( [[ "$CHECK_ONLY" == "1" ]] && echo "corrupt" || echo "fixed" )" \
        "$CURRENT_VAL"
else
    echo "[repair-main-worktree-config] INFRA-1060: stray core.worktree detected"
    echo "  value:    $CURRENT_VAL"
    echo "  git-dir:  $MAIN_GIT_DIR"
fi

if [[ "$CHECK_ONLY" == "1" ]]; then
    if [[ "$JSON_OUT" == "0" ]]; then
        echo "[repair-main-worktree-config] Run without --check to fix, or:"
        echo "  git --git-dir=\"$MAIN_GIT_DIR\" config --unset core.worktree"
    fi
    exit 1
fi

# Remove the stray key.
git --git-dir="$MAIN_GIT_DIR" config --unset core.worktree 2>/dev/null || true

# Verify removal.
AFTER="$(git --git-dir="$MAIN_GIT_DIR" config --local core.worktree 2>/dev/null || echo "")"
if [[ -n "$AFTER" ]]; then
    echo "[repair-main-worktree-config] ERROR: could not remove core.worktree (still: $AFTER)" >&2
    exit 1
fi

if [[ "$JSON_OUT" == "0" ]]; then
    echo "[repair-main-worktree-config] Fixed: core.worktree removed from main .git/config"
fi
exit 0
