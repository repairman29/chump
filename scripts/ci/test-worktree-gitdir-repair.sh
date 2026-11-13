#!/usr/bin/env bash
# RESILIENT-009: corrupt a fresh worktree's .git to point at a sibling's gitdir,
# then assert gap-claim.sh --verify-gitdir detects + repairs it.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
T="$(cd "$T" && pwd -P)"
git init -q "$T/repo" && cd "$T/repo"
git -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
git worktree add -q "$T/wt-a" -b a; git worktree add -q "$T/wt-b" -b b
printf 'gitdir: %s/.git/worktrees/wt-b\n' "$T/repo" > "$T/wt-a/.git"
export CHUMP_REPO="$T/repo" CHUMP_AMBIENT_LOG="$T/amb.jsonl"
bash "$ROOT/scripts/coord/gap-claim.sh" --verify-gitdir "$T/wt-a" TEST-1
[[ "$(cat "$T/wt-a/.git")" == "gitdir: $T/repo/.git/worktrees/wt-a" ]] || { echo "FAIL: pointer not repaired"; exit 1; }
[[ "$(git -C "$T/wt-a" rev-parse --show-toplevel)" == "$T/wt-a" ]] || { echo "FAIL: toplevel wrong"; exit 1; }
grep -q '"kind":"worktree_gitdir_repaired_postadd".*"expected_toplevel":"'"$T"'/wt-a"' "$T/amb.jsonl" || { echo "FAIL: no event"; exit 1; }
: > "$T/amb.jsonl"
bash "$ROOT/scripts/coord/gap-claim.sh" --verify-gitdir "$T/wt-b" TEST-2
[[ ! -s "$T/amb.jsonl" ]] || { echo "FAIL: healthy worktree emitted event"; exit 1; }
echo "PASS"
