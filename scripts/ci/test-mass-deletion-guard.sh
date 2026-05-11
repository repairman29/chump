#!/usr/bin/env bash
# test-mass-deletion-guard.sh — CREDIBLE-027: fixture-based tests for check-mass-deletion.sh

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
GUARD="$REPO_ROOT/scripts/ci/check-mass-deletion.sh"

pass() { printf '[PASS] %s\n' "$*"; }
fail() { printf '[FAIL] %s\n' "$*" >&2; exit 1; }

TMP="$(mktemp -d -t test-mass-del.XXXXXX)"
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

# ── Helper: create a throwaway git repo with a controlled diff ───────────────
make_repo() {
    local dir="$1"
    git init -q "$dir"
    git -C "$dir" config user.email "test@test.invalid"
    git -C "$dir" config user.name "Test"
    git -C "$dir" config commit.gpgsign false
}

# ── Test 1: vague commit title 'first' is flagged ────────────────────────────
REPO1="$TMP/repo1"
make_repo "$REPO1"
# base commit
printf 'initial content\n' > "$REPO1/file.txt"
git -C "$REPO1" add file.txt
git -C "$REPO1" commit -q -m "chore: init repo"
git -C "$REPO1" checkout -q -b feature
printf 'changed\n' > "$REPO1/file.txt"
git -C "$REPO1" add file.txt
git -C "$REPO1" commit -q -m "first"

out="$(cd "$REPO1" && GITHUB_BASE_REF=main bash "$GUARD" --warn-only 2>&1 || true)"
echo "$out" | grep -q "Vague commit title" || fail "Test 1: should detect 'first' as vague title"
pass "Test 1: vague commit 'first' flagged"

# ── Test 2: legitimate commit title passes ───────────────────────────────────
REPO2="$TMP/repo2"
make_repo "$REPO2"
printf 'initial content\n' > "$REPO2/file.txt"
git -C "$REPO2" add file.txt
git -C "$REPO2" commit -q -m "chore: init repo"
git -C "$REPO2" checkout -q -b feature
printf 'changed\n' > "$REPO2/file.txt"
git -C "$REPO2" add file.txt
git -C "$REPO2" commit -q -m "fix(auth): correct token expiry calculation"

out="$(cd "$REPO2" && GITHUB_BASE_REF=main bash "$GUARD" --warn-only 2>&1 || true)"
echo "$out" | grep -q "No vague commit titles" || fail "Test 2: clean commit should pass vague-title check"
pass "Test 2: clean commit title passes"

# ── Test 3: mass deletion from unrelated file is flagged (--warn-only) ───────
REPO3="$TMP/repo3"
make_repo "$REPO3"
# Create a file with 200 lines
python3 -c "print('\n'.join(f'line {i}' for i in range(200)))" > "$REPO3/bigfile.py"
printf 'readme content\n' > "$REPO3/README.md"
git -C "$REPO3" add bigfile.py README.md
git -C "$REPO3" commit -q -m "chore: initial"
git -C "$REPO3" checkout -q -b feature
# Delete most lines from bigfile.py (unrelated to commit message)
printf 'only one line left\n' > "$REPO3/bigfile.py"
git -C "$REPO3" add bigfile.py
git -C "$REPO3" commit -q -m "feat(README): update readme content"

out="$(cd "$REPO3" && GITHUB_BASE_REF=main bash "$GUARD" --warn-only 2>&1 || true)"
echo "$out" | grep -q "Mass deletion" || fail "Test 3: should detect mass deletion from bigfile.py (unrelated to 'readme')"
pass "Test 3: mass deletion from unrelated file flagged"

# ── Test 4: mass deletion from mentioned file passes ─────────────────────────
REPO4="$TMP/repo4"
make_repo "$REPO4"
python3 -c "print('\n'.join(f'line {i}' for i in range(200)))" > "$REPO4/bigfile.py"
git -C "$REPO4" add bigfile.py
git -C "$REPO4" commit -q -m "chore: initial"
git -C "$REPO4" checkout -q -b feature
printf 'refactored\n' > "$REPO4/bigfile.py"
git -C "$REPO4" add bigfile.py
# Commit message mentions 'bigfile' so mass deletion is intentional
git -C "$REPO4" commit -q -m "refactor(bigfile): collapse bigfile into single declaration"

out="$(cd "$REPO4" && GITHUB_BASE_REF=main bash "$GUARD" --warn-only 2>&1 || true)"
echo "$out" | grep -q "No mass unrelated deletions" || fail "Test 4: mentioned-file deletion should pass"
pass "Test 4: mentioned-file mass deletion passes"

# ── Test 5: --warn-only exits 0 even with violations ─────────────────────────
REPO5="$TMP/repo5"
make_repo "$REPO5"
printf 'x\n' > "$REPO5/f.txt"
git -C "$REPO5" add f.txt
git -C "$REPO5" commit -q -m "chore: initial"
git -C "$REPO5" checkout -q -b feature
printf 'y\n' > "$REPO5/f.txt"
git -C "$REPO5" add f.txt
git -C "$REPO5" commit -q -m "wip"

cd "$REPO5" && GITHUB_BASE_REF=main bash "$GUARD" --warn-only > /dev/null 2>&1 \
    && pass "Test 5: --warn-only exits 0 even with violations" \
    || fail "Test 5: --warn-only should not exit non-zero"

# ── Test 6: without --warn-only, violation exits 1 ───────────────────────────
REPO6="$TMP/repo6"
make_repo "$REPO6"
printf 'x\n' > "$REPO6/f.txt"
git -C "$REPO6" add f.txt
git -C "$REPO6" commit -q -m "chore: initial"
git -C "$REPO6" checkout -q -b feature
printf 'y\n' > "$REPO6/f.txt"
git -C "$REPO6" add f.txt
git -C "$REPO6" commit -q -m "init"

if cd "$REPO6" && GITHUB_BASE_REF=main bash "$GUARD" > /dev/null 2>&1; then
    fail "Test 6: should exit 1 on vague title without --warn-only"
else
    pass "Test 6: strict mode exits 1 on violation"
fi

echo ""
echo "All CREDIBLE-027 mass-deletion guard checks passed."
