#!/usr/bin/env bash
# test-infra-258-reaper-partial-delivery.sh — INFRA-258 regression test.
#
# Verifies the file-parity check inside scripts/ops/stale-pr-reaper.sh
# defers PR closure when the PR's diff includes files that are NOT yet
# byte-identical to origin/main.
#
# Pre-INFRA-258 the reaper closed any PR whose gap-IDs were `done` on
# main, even when the PR carried unique additional files (live incident
# 2026-05-02: PR #833's AGENTS.md doc was silently lost in such a close).
#
# This test does NOT spin up the full reaper script (it depends on `gh`
# + a remote). It exercises the file-parity logic directly via an
# inline shell snippet that mirrors the production code, so the
# regression boundary is the parity-check semantics: divergent file =
# defer close; identical files = close OK.

set -euo pipefail

# Tiny helper that mirrors the parity-check block from stale-pr-reaper.sh.
# Inputs:
#   $1 = path to a file containing the PR's file list (one path per line)
#   $2 = REMOTE/branch ref for the PR side  (e.g. "origin/feature")
#   $3 = REMOTE/branch ref for the base     (e.g. "origin/main")
# Outputs (stdout): list of divergent files (empty if all parity).
parity_check() {
    local files_path="$1" pr_ref="$2" base_ref="$3"
    local divergent=""
    while IFS= read -r f; do
        [[ -z "$f" ]] && continue
        local branch_blob main_blob
        branch_blob=$(git rev-parse "$pr_ref:$f" 2>/dev/null || echo "missing-on-branch")
        main_blob=$(git rev-parse "$base_ref:$f" 2>/dev/null || echo "missing-on-main")
        if [[ "$branch_blob" != "$main_blob" ]]; then
            divergent+="$f"$'\n'
        fi
    done < "$files_path"
    printf '%s' "$divergent"
}

TMP="$(cd "$(mktemp -d)" && pwd -P)"
trap 'rm -rf "$TMP"' EXIT

cd "$TMP"
git init -q -b main
git config user.email "test@chump.local"
git config user.name "Chump Test"

# Initial state on main: README + a/b/c.md
echo "init" > README.md
mkdir -p docs
echo "doc-a v1" > docs/a.md
echo "doc-b v1" > docs/b.md
echo "doc-c v1" > docs/c.md
git add . && git commit -qm "initial main: a/b/c"

# Create the "PR branch" with: a updated, b unchanged, c updated, d added.
git checkout -q -b feature
echo "doc-a v2-FROM-PR" > docs/a.md
echo "doc-c v2-FROM-PR" > docs/c.md
echo "doc-d v1-FROM-PR" > docs/d.md
git add . && git commit -qm "PR: update a/c, add d (b unchanged)"

# Simulate that "main" later landed PR-equivalents of a + c (matching content)
# but did NOT land d. This is the partial-delivery scenario.
git checkout -q main
echo "doc-a v2-FROM-PR" > docs/a.md     # same content as PR's a
echo "doc-c v2-FROM-PR" > docs/c.md     # same content as PR's c
git add . && git commit -qm "main: land a and c (forgot d)"

# The reaper would see "gap done on main" → would have closed the PR.
# But d is unique to the PR. Parity check must surface that.
PR_FILES_LIST="$TMP/.pr-files"
printf '%s\n' "docs/a.md" "docs/b.md" "docs/c.md" "docs/d.md" > "$PR_FILES_LIST"

DIVERGENT="$(parity_check "$PR_FILES_LIST" "feature" "main")"

# ── Test 1: parity check surfaces the unique file (d) ────────────────────────
echo "Test 1: PR has 4 files, main has 3 of them in same content, 1 unique → divergent must list d"
if echo "$DIVERGENT" | grep -q "^docs/d.md$"; then
    echo "[PASS] divergent list includes the unique file (docs/d.md)"
else
    echo "[FAIL] INFRA-258 regression: divergent list missing the unique file"
    echo "       got divergent='$DIVERGENT'"
    exit 1
fi

# ── Test 2: matching files (a, c) are NOT in the divergent list ──────────────
echo ""
echo "Test 2: matching files must not appear in divergent list"
if echo "$DIVERGENT" | grep -qE "^docs/(a|c)\.md$"; then
    echo "[FAIL] divergent list incorrectly includes a matching file (false partial)"
    echo "       got divergent='$DIVERGENT'"
    exit 1
else
    echo "[PASS] matching files excluded from divergent list"
fi

# ── Test 3: full-parity case (all files identical) → empty divergent ─────────
echo ""
echo "Test 3: all files match → divergent must be empty (close OK)"
PR_FILES_FULL_PARITY="$TMP/.pr-files-parity"
printf '%s\n' "docs/a.md" "docs/b.md" "docs/c.md" > "$PR_FILES_FULL_PARITY"
DIVERGENT2="$(parity_check "$PR_FILES_FULL_PARITY" "feature" "main")"
if [[ -z "$DIVERGENT2" ]]; then
    echo "[PASS] full parity → empty divergent (reaper would close PR)"
else
    echo "[FAIL] full parity should produce empty divergent, got: '$DIVERGENT2'"
    exit 1
fi

# ── Test 4: file missing on main → counted as divergent ──────────────────────
echo ""
echo "Test 4: file present on PR branch but missing on main → divergent"
PR_FILES_MISSING="$TMP/.pr-files-missing"
printf '%s\n' "docs/d.md" > "$PR_FILES_MISSING"
DIVERGENT3="$(parity_check "$PR_FILES_MISSING" "feature" "main")"
if echo "$DIVERGENT3" | grep -q "^docs/d.md$"; then
    echo "[PASS] missing-on-main file is divergent"
else
    echo "[FAIL] missing-on-main file should be divergent"
    exit 1
fi

echo ""
echo "[OK] all 4 INFRA-258 partial-delivery cases passed"
