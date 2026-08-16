#!/usr/bin/env bash
# branch-mutex.sh — INFRA-1966. Shared per-branch advisory lock primitive.
#
# Multiple bash orchestrators (pr-auto-rebase.sh, queue-driver.sh,
# armed-pr-rebaser.sh) independently run `git worktree add` + `git rebase
# origin/main` + `git push --force-with-lease` against the SAME branch. Only
# pr-auto-rebase.sh (INFRA-1974) took a per-branch flock before this; the
# other two raced unprotected — two orchestrators rebasing/pushing the same
# branch concurrently can interleave force-pushes or collide on the shared
# `git worktree add <dir> <branch>` administrative files under .git/worktrees.
#
# This extracts the INFRA-1974 lockfile convention (.chump-locks/rebase-<branch>.lock)
# into a shared helper so every caller contends on the SAME lock per branch,
# regardless of which script is driving the rebase.
#
# Usage:
#   # shellcheck source=scripts/coord/lib/branch-mutex.sh
#   source "$(dirname "$0")/lib/branch-mutex.sh"
#   if acquire_branch_lock "$branch" "$REPO_ROOT"; then
#       ... git worktree add / rebase / push ...
#       release_branch_lock
#   else
#       echo "branch locked by another orchestrator — deferring"
#   fi
#
# Bypass: CHUMP_BRANCH_MUTEX_NO_LOCK=1 skips locking entirely (matches the
# CHUMP_PR_AUTO_REBASE_NO_LOCK escape hatch already used by pr-auto-rebase.sh).

# Acquire the per-branch lock. Opens FD 9 (loop/subshell scoped) — call
# release_branch_lock to close it, or let process exit release it implicitly.
# Args: $1 branch name, $2 repo root (for the .chump-locks dir), $3 wait
# seconds (default 1 — orchestrators are expected to defer quickly and retry
# next cycle rather than block).
# Returns 0 on acquired, 1 on held-by-other/unavailable.
acquire_branch_lock() {
    local branch="$1"
    local repo_root="${2:-.}"
    local wait_s="${3:-1}"

    if [[ "${CHUMP_BRANCH_MUTEX_NO_LOCK:-0}" == "1" ]] || ! command -v flock >/dev/null 2>&1; then
        return 0
    fi

    local branch_safe="${branch//\//_}"
    local lock_dir="${LOCK_DIR:-$repo_root/.chump-locks}"
    mkdir -p "$lock_dir" 2>/dev/null || true
    BRANCH_MUTEX_LOCKFILE="$lock_dir/rebase-${branch_safe}.lock"

    exec 9>"$BRANCH_MUTEX_LOCKFILE" || return 1
    if ! flock -n -w "$wait_s" 9; then
        exec 9>&- 2>/dev/null || true
        return 1
    fi
    return 0
}

# Release the lock acquired by acquire_branch_lock. Safe to call even if no
# lock was held (e.g. CHUMP_BRANCH_MUTEX_NO_LOCK=1 path).
release_branch_lock() {
    exec 9>&- 2>/dev/null || true
}
