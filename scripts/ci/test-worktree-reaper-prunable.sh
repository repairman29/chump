#!/usr/bin/env bash
# test-worktree-reaper-prunable.sh — RESILIENT-128
# A worktree whose directory vanished (git marks it "prunable") must be
# deregistered by stale-worktree-reaper.sh and emit kind=worktree_reaped_prunable.
set -euo pipefail

REAPER="$(cd "$(dirname "$0")/../ops" && pwd)/stale-worktree-reaper.sh"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT

REPO="$T/repo"
mkdir -p "$REPO/.chump-locks" "$REPO/scripts"
ln -s "$(cd "$(dirname "$REAPER")/../lib" && pwd)" "$REPO/scripts/lib"
git -C "$REPO" init -q -b main
git -C "$REPO" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
git init -q --bare -b main "$T/origin.git"
git -C "$REPO" remote add origin "$T/origin.git"
git -C "$REPO" push -q origin main
git -C "$REPO" fetch -q origin
git -C "$REPO" worktree add -q -b chump/prunable-test "$T/chump-prunable-test"
rm -rf "$T/chump-prunable-test"

if ! git -C "$REPO" worktree list --porcelain | grep -q '^prunable'; then
    echo "[FAIL] setup: git did not mark worktree prunable"; exit 1
fi

AMBIENT="$T/ambient.jsonl"
CHUMP_WORKTREE_BASE="$T" CHUMP_REPO_ROOT_OVERRIDE="$REPO" CHUMP_AMBIENT_LOG="$AMBIENT" \
    WORKTREE_SCAN_PATHS="$T/nomatch-*" \
    bash "$REAPER" --execute >"$T/out.log" 2>&1 || { cat "$T/out.log"; echo "[FAIL] reaper exited non-zero"; exit 1; }

if git -C "$REPO" worktree list --porcelain | grep -q 'chump-prunable-test'; then
    cat "$T/out.log"; echo "[FAIL] prunable registration still present"; exit 1
fi
echo "[PASS] prunable registration removed"

if ! grep -q '"kind":"worktree_reaped_prunable"' "$AMBIENT" 2>/dev/null \
   || ! grep -q '"prior_branch":"' "$AMBIENT" || ! grep -q '"age":"' "$AMBIENT"; then
    cat "$T/out.log"; cat "$AMBIENT" 2>/dev/null || true
    echo "[FAIL] worktree_reaped_prunable event missing/incomplete"; exit 1
fi
echo "[PASS] worktree_reaped_prunable emitted with prior_branch + age"
echo "[OK] RESILIENT-128 prunable reaper test passed"
