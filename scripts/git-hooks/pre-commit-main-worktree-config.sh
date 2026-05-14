#!/usr/bin/env bash
# pre-commit-main-worktree-config.sh — INFRA-1060 (2026-05-13)
#
# Guard: refuse commit when the MAIN repo's .git/config has core.worktree
# pointing at a /tmp path. That setting silently redirects all git operations
# (gap YAML writes, 'git status', 'git rev-parse --show-toplevel') to a
# sibling agent's worktree — causing wrong-path writes that corrupt the
# gap registry and the next bot-merge.
#
# If the stale key is detected, auto-removes it (safe: the key must never
# exist in the main config by design).  If auto-repair fails, blocks the
# commit so the operator can fix manually:
#   git config --unset core.worktree
# or:
#   scripts/ops/repair-main-worktree-config.sh
#
# Bypass: CHUMP_MAIN_WT_CONFIG_CHECK=0 (no trailer required for this check
# since removing the key is always correct and the bypass is only needed
# when git-dir detection itself is broken).

set -euo pipefail

# Resolve the main repo's git dir.
# Accept MAIN_GIT_DIR directly (for testing) or derive from REPO_ROOT / CWD.
if [[ -z "${MAIN_GIT_DIR:-}" ]]; then
    if [[ -n "${REPO_ROOT:-}" && -d "${REPO_ROOT}/.git" ]]; then
        MAIN_GIT_DIR="${REPO_ROOT}/.git"
    else
        MAIN_GIT_DIR="$(git rev-parse --git-common-dir 2>/dev/null || echo "")"
    fi
fi

# Only run this guard when we're in the MAIN checkout (not in a linked
# worktree whose git-dir is .git/worktrees/<name>).
if [[ -z "$MAIN_GIT_DIR" ]] || [[ "$MAIN_GIT_DIR" == *"/worktrees/"* ]]; then
    # In a linked worktree — skip this check (worktrees have their own config).
    exit 0
fi

if [[ ! -d "$MAIN_GIT_DIR" ]]; then
    exit 0
fi

# Check for stray core.worktree in the main config (--local = repo config only).
STRAY_VAL="$(git --git-dir="$MAIN_GIT_DIR" config --local core.worktree 2>/dev/null || echo "")"
if [[ -z "$STRAY_VAL" ]]; then
    exit 0  # clean
fi

echo "[pre-commit] INFRA-1060: stray core.worktree detected in main .git/config:" >&2
echo "[pre-commit]   core.worktree = $STRAY_VAL" >&2
echo "[pre-commit] This setting silently redirects git operations to a sibling worktree." >&2

if [[ "${CHUMP_MAIN_WT_CONFIG_CHECK:-1}" == "0" ]]; then
    echo "[pre-commit] CHUMP_MAIN_WT_CONFIG_CHECK=0: skipping guard (bypass active)" >&2
    exit 0
fi

# Auto-repair: remove the stray key.
if git --git-dir="$MAIN_GIT_DIR" config --unset core.worktree 2>/dev/null; then
    echo "[pre-commit] INFRA-1060: auto-removed stray core.worktree — commit continuing." >&2
    exit 0
fi

# Auto-repair failed — block the commit.
echo "[pre-commit] INFRA-1060: auto-repair failed. Fix manually:" >&2
echo "[pre-commit]   git config --unset core.worktree" >&2
echo "[pre-commit]   # or:" >&2
echo "[pre-commit]   scripts/ops/repair-main-worktree-config.sh" >&2
exit 1
