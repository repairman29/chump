#!/usr/bin/env bash
# resolve-main-worktree.sh — INFRA-451
#
# Resolves the absolute path of the *main* (non-linked) git worktree, regardless
# of whether the caller is running from the main repo or a linked worktree under
# .chump/worktrees/<name>/ or /tmp/<name>/.
#
# Why: launchd install scripts previously did
#     REPO="$(cd "$(dirname "$0")/../.." && pwd)"
# which baked the *current* worktree's absolute path into the plist. If a user
# happened to install while sitting in /tmp/chump-foo (e.g. during a fleet
# session), the plist's WorkingDirectory + ProgramArguments referenced
# /tmp/chump-foo. When the worktree was later reaped by stale-worktree-reaper,
# rebooted away (macOS clears /tmp), or simply removed by the user, every
# subsequent launchd run silently no-op'd. Root cause of the 4-of-5 reapers
# silent-24h+ episode that motivated this gap.
#
# Usage:
#   source "$(dirname "$0")/../lib/resolve-main-worktree.sh"
#   REPO="$(resolve_main_worktree "$0")"
#
# Arg: an absolute or relative path to a script *inside* the repo. We resolve
# starting from its directory so the function works even when called with a
# relative $0 (e.g. `bash scripts/setup/install-foo.sh` from any cwd).
#
# Output: absolute path to the main worktree, or exit 1 if it can't be
# resolved (caller is not inside any git tree).
resolve_main_worktree() {
  local script_path="${1:?usage: resolve_main_worktree <script-path>}"
  local script_dir
  script_dir="$(cd "$(dirname "$script_path")" 2>/dev/null && pwd)" || return 1

  # `git worktree list --porcelain` always emits the main worktree first.
  # Format starts with `worktree <abs-path>` on the first line.
  local main_wt
  main_wt="$(git -C "$script_dir" worktree list --porcelain 2>/dev/null \
              | awk '/^worktree / {print $2; exit}')"

  if [[ -z "$main_wt" ]]; then
    return 1
  fi
  printf '%s\n' "$main_wt"
}

# When sourced, the function is exported. When executed directly, behave as a
# CLI: `resolve-main-worktree.sh <script-path>` prints the main worktree.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  resolve_main_worktree "${1:-$0}"
fi
