#!/usr/bin/env bash
# INFRA-987 / RESILIENT-009: thin wrapper delegating to `chump claim` with
# post-add worktree `.git` pointer verification + repair (`worktree_gitdir_repaired_postadd`).
set -euo pipefail
verify_and_repair_worktree_gitdir() {
    local wt_dir="$1" gap_id="${2:-}" repo_root="${CHUMP_REPO:-$(pwd)}"
    [[ -d "$wt_dir" ]] || return 0
    local expected_top observed_top=""
    expected_top="$(cd "$wt_dir" && pwd -P)"
    observed_top="$(git -C "$wt_dir" rev-parse --show-toplevel 2>/dev/null || true)"
    [[ -n "$observed_top" ]] && observed_top="$(cd "$observed_top" 2>/dev/null && pwd -P || echo "$observed_top")"
    local want_ptr="gitdir: $repo_root/.git/worktrees/$(basename "$wt_dir")" have_ptr=""
    [[ -f "$wt_dir/.git" ]] && have_ptr="$(tr -d '\r\n' < "$wt_dir/.git" || true)"
    if [[ "$observed_top" != "$expected_top" || ( -f "$wt_dir/.git" && "$have_ptr" != "$want_ptr" ) ]]; then
        local git_file="$wt_dir/.git" wt_name old_ptr="" expected_gitdir
        wt_name="$(basename "$wt_dir")"
        expected_gitdir="$repo_root/.git/worktrees/$wt_name"
        [[ -f "$git_file" ]] && old_ptr="$(tr -d '\r\n' < "$git_file" || true)"
        mkdir -p "$expected_gitdir" 2>/dev/null || true
        printf 'gitdir: %s\n' "$expected_gitdir" > "$git_file"
        printf '%s/.git\n' "$wt_dir" > "$expected_gitdir/gitdir"
        printf '../..\n' > "$expected_gitdir/commondir"
        git -C "$repo_root" worktree repair "$wt_dir" >/dev/null 2>&1 || true
        local amb="${CHUMP_AMBIENT_LOG:-$repo_root/.chump-locks/ambient.jsonl}"
        mkdir -p "$(dirname "$amb")" 2>/dev/null || true
        # scanner-anchor: "kind":"worktree_gitdir_repaired_postadd"
        printf '{"ts":"%s","kind":"worktree_gitdir_repaired_postadd","worktree":"%s","gap_id":"%s","repaired_from":"%s","repaired_to":"gitdir: %s","path":"%s","expected_toplevel":"%s","observed_toplevel":"%s"}\n' \
            "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$wt_dir" "$gap_id" "$old_ptr" "$expected_gitdir" "$wt_dir" "$expected_top" "$observed_top" >> "$amb" 2>/dev/null || true
    fi
    [[ "$(cd "$(git -C "$wt_dir" rev-parse --show-toplevel)" && pwd -P)" == "$expected_top" ]]
}
if [[ "${1:-}" == "--verify-gitdir" ]]; then
    shift; verify_and_repair_worktree_gitdir "$@"; exit $?
fi
[[ "${BASH_SOURCE[0]}" == "$0" ]] && exec chump claim "$@"
