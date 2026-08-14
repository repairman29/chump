#!/usr/bin/env bash
# index-mutex-path.sh — shared resolver for chump-commit's git-index mutex
# path (RESILIENT-117).
#
# Root cause: the previous mutex path, `$(git rev-parse --git-dir)/.chump-index-mutex`,
# lives *inside* the linked worktree's own git-dir
# ($MAIN_REPO/.git/worktrees/<name>/). Two failure modes converge there:
#
#   1. /tmp -> /private/tmp symlink aliasing (INFRA-779 family): depending on
#      which alias a caller's $PWD was resolved through when the worktree was
#      created vs. when a later process re-resolves --git-dir, string-different
#      but canonically-identical paths can produce two *different* lock files
#      for what should be the same worktree — or, worse, tooling that
#      normalizes one side but not the other can collide two worktrees onto
#      what lsof reports as the same inode.
#   2. FD 200 (opened via `exec 200>>...` in chump-commit.sh) is inherited by
#      every child process spawned afterward — including the pre-commit hook's
#      `cargo fmt`/`cargo clippy` calls. A long-lived build daemon (sccache)
#      forked from that hook keeps its inherited copy of FD 200 open for as
#      long as the daemon runs, i.e. long after chump-commit.sh itself has
#      exited — so `lsof` shows FD 200 on worktree X's mutex held by a
#      process whose own --out-dir/target argument belongs to worktree Y
#      (whichever worktree's build the daemon happens to be servicing now).
#
# Fix (this file): make the mutex path a function of the worktree's own
# canonicalized (symlink-resolved) directory name, rooted under the shared
# main-repo .chump-locks/ directory rather than inside the git-dir. This
# keeps the path stable and unique per worktree regardless of /tmp aliasing,
# and — because .chump-locks/ already ships reaper/cleanup tooling — gives
# the mutex file the same lifecycle guarantees as every other lease file.
#
# Usage:
#   source "$(dirname "$0")/../lib/index-mutex-path.sh"
#   MUTEX="$(chump_index_mutex_path)" || exit 1
set -u

_INDEX_MUTEX_PATH_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./resolve-main-worktree.sh
# shellcheck disable=SC1091
source "$_INDEX_MUTEX_PATH_LIB_DIR/resolve-main-worktree.sh"

chump_index_mutex_path() {
  local repo_root main_repo lock_dir slug

  repo_root="$(git rev-parse --show-toplevel 2>/dev/null)" || return 1
  # Canonicalize (resolve symlinks, incl. /tmp -> /private/tmp on macOS) so
  # the slug is stable no matter which alias the caller's $PWD went through.
  repo_root="$(cd "$repo_root" 2>/dev/null && pwd -P)" || return 1

  # Resolve relative to the CALLER's repo (repo_root), not this library
  # file's own location — otherwise `git worktree list` would always query
  # the chump repo this file lives in, regardless of which repo/worktree the
  # caller is actually operating in.
  main_repo="$(resolve_main_worktree "$repo_root/.")"
  if [[ -z "$main_repo" ]]; then
    # Fall back to the current repo root — covers the (rare) case of a
    # detached/bare checkout with no `git worktree list` output.
    main_repo="$repo_root"
  fi
  main_repo="$(cd "$main_repo" 2>/dev/null && pwd -P)" || return 1

  lock_dir="$main_repo/.chump-locks"
  mkdir -p "$lock_dir" 2>/dev/null || return 1

  slug="$(basename "$repo_root")"
  printf '%s/index-mutex-%s.lock\n' "$lock_dir" "$slug"
}

# CLI form for ad-hoc inspection / the validation test.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  chump_index_mutex_path
fi
