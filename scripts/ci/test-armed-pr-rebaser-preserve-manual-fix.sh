#!/usr/bin/env bash
# scripts/ci/test-armed-pr-rebaser-preserve-manual-fix.sh — RESILIENT-350
#
# Reproduces the exact clobber bug described in RESILIENT-350: the
# fleet detects a BROKEN PR (deterministic lint/test failure),
# rebase-loops it via armed-pr-rebaser.sh, and the rebaser silently
# reverts a commit that was pushed straight to the PR branch (a manual
# fix) because it rebased from a STALE local branch ref instead of the
# fetched remote tip.
#
# Fixture:
#   - bare "origin" repo with main + a PR branch (commit A: buggy raw
#     `gh` call, mirrors the raw-gh lint failure in the evidence).
#   - $ROOT (armed-pr-rebaser's CHUMP_REPO_ROOT) has ALREADY seen this
#     branch once before (simulating a prior claim/worktree) — so its
#     local branch ref is pinned at commit A.
#   - A sibling clone pushes commit B directly to origin/<branch>: the
#     "manual fix" that flips the raw call to the safe wrapper.
#   - main also advances (commit C) so the PR is DIRTY/behind and
#     armed-pr-rebaser.sh picks it up.
#
# Expectation: after armed-pr-rebaser.sh runs and force-pushes, the
# fixed file on origin/<branch> must still contain the manual fix (B),
# rebased on top of main's advance (C). The pre-fix script drops B
# entirely because it rebases $ROOT's stale local ref (pinned at A).

set -uo pipefail

PASS=0
FAIL=0
FAILS=()
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); FAILS+=("$1"); }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TARGET="$REPO_ROOT/scripts/coord/armed-pr-rebaser.sh"

echo "=== RESILIENT-350 armed-pr-rebaser preserve-manual-fix tests ==="

[[ -f "$TARGET" ]] && ok "script exists" || { fail "missing $TARGET"; exit 1; }

# ── Source-contract: worktree must be built from the fetched remote tip ──
if grep -qE 'git worktree add -B "\$br" "\$wt" "origin/\$br"' "$TARGET"; then
    ok "contract: worktree add builds from origin/\$br (not a stale local ref)"
else
    fail "contract: worktree add no longer builds from origin/\$br — clobber regression"
fi
if grep -qE 'git worktree add "\$wt" "\$br"' "$TARGET"; then
    fail "contract: found the old bare-branch-name worktree add (stale-ref clobber bug)"
else
    ok "contract: old bare-branch-name worktree add is gone"
fi

TMP="$(mktemp -d -t armed-pr-rebaser-test-XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

# ── Build bare "origin" ────────────────────────────────────────────────────
ORIGIN="$TMP/origin.git"
git init -q --bare -b main "$ORIGIN"

SEED="$TMP/seed"
git init -q -b main "$SEED"
git -C "$SEED" config user.email "test@example.com"
git -C "$SEED" config user.name "Test Seed"
echo "root" > "$SEED/README.md"
git -C "$SEED" add README.md
git -C "$SEED" commit -q -m "init"
git -C "$SEED" remote add origin "$ORIGIN"
git -C "$SEED" push -q origin main

# PR branch, commit A: the buggy raw `gh` call.
git -C "$SEED" checkout -q -b pr-branch
mkdir -p "$SEED/scripts/coord"
cat > "$SEED/scripts/coord/keep-mergeable.sh" <<'EOF'
raw_call() { gh pr comment "$1" --body "$2"; }
EOF
git -C "$SEED" add scripts/coord/keep-mergeable.sh
git -C "$SEED" commit -q -m "add keep-mergeable (raw gh call, commit A)"
git -C "$SEED" push -q origin pr-branch

# ── $ROOT: simulate armed-pr-rebaser's own checkout having seen this
# branch before (a prior claim/worktree), pinning its local ref at A. ──
ROOT="$TMP/root"
git clone -q "$ORIGIN" "$ROOT"
git -C "$ROOT" config user.email "test@example.com"
git -C "$ROOT" config user.name "Test Root"
git -C "$ROOT" branch pr-branch origin/pr-branch   # local ref pinned at commit A
mkdir -p "$ROOT/.chump-locks"

# ── Sibling clone pushes the MANUAL FIX (commit B) straight to origin. ────
FIXER="$TMP/fixer"
git clone -q "$ORIGIN" "$FIXER"
git -C "$FIXER" config user.email "test@example.com"
git -C "$FIXER" config user.name "Test Fixer"
git -C "$FIXER" checkout -q pr-branch
cat > "$FIXER/scripts/coord/keep-mergeable.sh" <<'EOF'
raw_call() { chump_gh pr comment "$1" --body "$2"; }
EOF
git -C "$FIXER" add scripts/coord/keep-mergeable.sh
git -C "$FIXER" commit -q -m "fix raw gh call -> chump_gh (manual fix, commit B)"
git -C "$FIXER" push -q origin pr-branch

# ── main advances (commit C) so the PR is DIRTY/behind. ───────────────────
git -C "$FIXER" checkout -q main
echo "advance" >> "$FIXER/README.md"
git -C "$FIXER" add README.md
git -C "$FIXER" commit -q -m "advance main (commit C)"
git -C "$FIXER" push -q origin main

# ── Stub gh: armed-pr-rebaser only needs `gh pr list`. ─────────────────────
mkdir -p "$TMP/bin"
cat > "$TMP/bin/gh" <<'EOF'
#!/usr/bin/env bash
case "$1" in
    pr)
        case "$2" in
            list)
                cat <<JSON
[
  {"number": 4242, "mergeStateStatus": "DIRTY", "autoMergeRequest": {"mergeMethod": "SQUASH"}, "headRefName": "pr-branch"}
]
JSON
                ;;
        esac
        ;;
esac
exit 0
EOF
chmod +x "$TMP/bin/gh"

# ── Run the (fixed) target script against $ROOT. ───────────────────────────
OUT="$(PATH="$TMP/bin:$PATH" CHUMP_REPO_ROOT="$ROOT" CHUMP_PR_REPO="test/repo" bash "$TARGET" 2>&1)"

if echo "$OUT" | grep -q "rebased clean + pushed"; then
    ok "runtime: rebase reported clean + pushed"
else
    fail "runtime: did not report a clean rebase+push; got: $OUT"
fi

# ── Verify the manual fix (commit B's content) SURVIVED on origin. ────────
FINAL_CONTENT="$(git -C "$ORIGIN" show "refs/heads/pr-branch:scripts/coord/keep-mergeable.sh" 2>/dev/null || true)"
if echo "$FINAL_CONTENT" | grep -q "chump_gh"; then
    ok "runtime: manual fix (commit B, chump_gh) survived the rebase+push"
else
    fail "runtime: manual fix was CLOBBERED — origin/pr-branch shows: $FINAL_CONTENT"
fi
if echo "$FINAL_CONTENT" | grep -qE '^raw_call\(\) \{ gh pr comment'; then
    fail "runtime: buggy raw gh call (commit A) reappeared without the fix — clobber confirmed"
fi

# Also confirm the rebase actually picked up main's advance (commit C),
# i.e. this is a real rebase-and-preserve, not just "didn't touch it".
README_ON_BRANCH="$(git -C "$ORIGIN" show "refs/heads/pr-branch:README.md" 2>/dev/null || true)"
if echo "$README_ON_BRANCH" | grep -q "advance"; then
    ok "runtime: rebase correctly picked up main's advance (commit C)"
else
    fail "runtime: pr-branch does not contain main's advance — rebase did not happen"
fi

echo ""
echo "=== RESULTS: $PASS passed, $FAIL failed ==="
if [[ $FAIL -gt 0 ]]; then
    printf '  - %s\n' "${FAILS[@]}"
    exit 1
fi
exit 0
