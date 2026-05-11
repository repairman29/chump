#!/usr/bin/env bash
# test-pr-scope-honesty.sh — CREDIBLE-026: fixture-based tests for check-pr-scope.sh

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
GUARD="$REPO_ROOT/scripts/ci/check-pr-scope.sh"

pass() { printf '[PASS] %s\n' "$*"; }
fail() { printf '[FAIL] %s\n' "$*" >&2; exit 1; }

TMP="$(mktemp -d -t test-pr-scope.XXXXXX)"
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

make_repo() {
    local dir="$1"
    git init -q "$dir"
    git -C "$dir" config user.email "test@test.invalid"
    git -C "$dir" config user.name "Test"
    git -C "$dir" config commit.gpgsign false
}

# ── Test 1: chore(gaps) with only gap YAML changes — should pass ──────────────
REPO1="$TMP/repo1"
make_repo "$REPO1"
mkdir -p "$REPO1/docs/gaps"
printf 'id: TEST-001\n' > "$REPO1/docs/gaps/TEST-001.yaml"
git -C "$REPO1" add .
git -C "$REPO1" commit -q -m "chore: base"
git -C "$REPO1" checkout -q -b feature
printf 'id: TEST-001\npriority: P2\n' > "$REPO1/docs/gaps/TEST-001.yaml"
git -C "$REPO1" add .
git -C "$REPO1" commit -q -m "chore(gaps): demote TEST-001 to P2"

out="$(cd "$REPO1" && GITHUB_BASE_REF=main bash "$GUARD" --warn-only 2>&1 || true)"
echo "$out" | grep -q "chore.gaps. prefix matches" || fail "Test 1: gap-only chore(gaps) PR should pass Rule A"
pass "Test 1: chore(gaps) with only YAML passes"

# ── Test 2: chore(gaps) with src/ change — should fail Rule A ────────────────
REPO2="$TMP/repo2"
make_repo "$REPO2"
mkdir -p "$REPO2/docs/gaps" "$REPO2/src"
printf 'id: TEST-002\n' > "$REPO2/docs/gaps/TEST-002.yaml"
printf 'fn main() {}\n' > "$REPO2/src/main.rs"
git -C "$REPO2" add .
git -C "$REPO2" commit -q -m "chore: base"
git -C "$REPO2" checkout -q -b feature
printf 'id: TEST-002\npriority: P1\n' > "$REPO2/docs/gaps/TEST-002.yaml"
printf 'fn main() { println!("changed"); }\n' > "$REPO2/src/main.rs"
git -C "$REPO2" add .
git -C "$REPO2" commit -q -m "chore(gaps): update TEST-002"

out="$(cd "$REPO2" && GITHUB_BASE_REF=main bash "$GUARD" --warn-only 2>&1 || true)"
echo "$out" | grep -q "Rule A" || fail "Test 2: chore(gaps) with src/ change should trigger Rule A"
pass "Test 2: chore(gaps) with src/ change triggers Rule A"

# ── Test 3: feat prefix with src/ change — should pass (not a gaps PR) ───────
REPO3="$TMP/repo3"
make_repo "$REPO3"
mkdir -p "$REPO3/src"
printf 'fn main() {}\n' > "$REPO3/src/main.rs"
git -C "$REPO3" add .
git -C "$REPO3" commit -q -m "chore: base"
git -C "$REPO3" checkout -q -b feature
printf 'fn main() { println!("feat"); }\n' > "$REPO3/src/main.rs"
git -C "$REPO3" add .
git -C "$REPO3" commit -q -m "feat(CREDIBLE-026): add scope checker"

out="$(cd "$REPO3" && GITHUB_BASE_REF=main bash "$GUARD" --warn-only 2>&1 || true)"
echo "$out" | grep -q "non-gaps-only prefix" || fail "Test 3: feat prefix should skip Rule A check"
pass "Test 3: feat prefix with src/ change passes (not a gaps PR)"

# ── Test 4: explicit Revert commit skips Rule B ────────────────────────────────
REPO4="$TMP/repo4"
make_repo "$REPO4"
printf 'content\n' > "$REPO4/file.txt"
git -C "$REPO4" add .
git -C "$REPO4" commit -q -m "chore: base"
git -C "$REPO4" checkout -q -b feature
rm "$REPO4/file.txt"
git -C "$REPO4" add .
git -C "$REPO4" commit -q -m "Revert: remove file.txt (was incorrect)"

out="$(cd "$REPO4" && GITHUB_BASE_REF=main bash "$GUARD" --warn-only 2>&1 || true)"
echo "$out" | grep -q "explicit Revert commit" || fail "Test 4: explicit Revert should skip Rule B"
pass "Test 4: explicit Revert commit skips Rule B"

# ── Test 5: --warn-only exits 0 even with violations ─────────────────────────
REPO5="$TMP/repo5"
make_repo "$REPO5"
mkdir -p "$REPO5/docs/gaps" "$REPO5/src"
printf 'id: X\n' > "$REPO5/docs/gaps/X.yaml"
printf 'fn main() {}\n' > "$REPO5/src/main.rs"
git -C "$REPO5" add .
git -C "$REPO5" commit -q -m "chore: base"
git -C "$REPO5" checkout -q -b feature
printf 'id: X\npriority: P1\n' > "$REPO5/docs/gaps/X.yaml"
printf 'fn main() { println!("bad"); }\n' > "$REPO5/src/main.rs"
git -C "$REPO5" add .
git -C "$REPO5" commit -q -m "chore(gaps): update X"

cd "$REPO5" && GITHUB_BASE_REF=main bash "$GUARD" --warn-only > /dev/null 2>&1 \
    && pass "Test 5: --warn-only exits 0 on violation" \
    || fail "Test 5: --warn-only should not exit non-zero"

# ── Test 6: strict mode exits 1 on Rule A violation ──────────────────────────
if cd "$REPO5" && GITHUB_BASE_REF=main bash "$GUARD" > /dev/null 2>&1; then
    fail "Test 6: strict mode should exit 1 on Rule A violation"
else
    pass "Test 6: strict mode exits 1 on violation"
fi

echo ""
echo "All CREDIBLE-026 PR scope-honesty checks passed."
