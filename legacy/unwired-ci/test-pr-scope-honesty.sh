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


# ── Tests 7-9: Rule C (no-bundle-PR, CREDIBLE-041) ───────────────────────────

make_state_db() {
    local dir="$1"
    mkdir -p "$dir/.chump"
    sqlite3 "$dir/.chump/state.db" << 'SQL'
CREATE TABLE gaps (
  id TEXT PRIMARY KEY,
  depends_on TEXT NOT NULL DEFAULT ''
);
INSERT INTO gaps (id, depends_on) VALUES
  ('INFRA-1', ''),
  ('INFRA-2', ''),
  ('EFFECTIVE-009', ''),
  ('EVAL-086', ''),
  ('INFRA-825', ''),
  ('INFRA-100', '["INFRA-101"]'),
  ('INFRA-101', '');
SQL
}

# Test 7: bundle title with 3 unrelated gaps → FAIL (CREDIBLE-041 fixture: PR #1469)
REPO7="$TMP/repo7"
make_repo "$REPO7"
make_state_db "$REPO7"
printf 'x\n' > "$REPO7/file.txt"
git -C "$REPO7" add file.txt
git -C "$REPO7" commit -q -m "chore: init"
git -C "$REPO7" checkout -q -b feature
printf 'y\n' > "$REPO7/file.txt"
git -C "$REPO7" add file.txt
git -C "$REPO7" commit -q -m "feat(effective-009,eval-086,infra-825): bundle unrelated gaps"

out="$(cd "$REPO7" && CHUMP_REPO="$REPO7" GITHUB_BASE_REF=main bash "$GUARD" --warn-only 2>&1 || true)"
if echo "$out" | grep -q "no-bundle-PR\|bundle_blocked\|CREDIBLE-041"; then
    pass "Test 7: bundle title (3 unrelated gap IDs) triggers Rule C"
else
    fail "Test 7: should detect bundle of unrelated gaps: $out"
fi

# Test 8: bundle title with depends_on-linked gaps → PASS
REPO8="$TMP/repo8"
make_repo "$REPO8"
make_state_db "$REPO8"
printf 'x\n' > "$REPO8/file.txt"
git -C "$REPO8" add file.txt
git -C "$REPO8" commit -q -m "chore: init"
git -C "$REPO8" checkout -q -b feature
printf 'y\n' > "$REPO8/file.txt"
git -C "$REPO8" add file.txt
git -C "$REPO8" commit -q -m "feat(infra-100,infra-101): ship linked gaps together"

out="$(cd "$REPO8" && CHUMP_REPO="$REPO8" GITHUB_BASE_REF=main bash "$GUARD" --warn-only 2>&1 || true)"
if echo "$out" | grep -q "no-bundle-PR\|bundle_blocked\|Rule C.*unrelated"; then
    fail "Test 8: depends_on-linked gaps should PASS Rule C: $out"
else
    pass "Test 8: depends_on-linked bundle passes Rule C"
fi

# Test 9: single gap ID in title → PASS (not a bundle)
REPO9="$TMP/repo9"
make_repo "$REPO9"
printf 'x\n' > "$REPO9/file.txt"
git -C "$REPO9" add file.txt
git -C "$REPO9" commit -q -m "chore: init"
git -C "$REPO9" checkout -q -b feature
printf 'y\n' > "$REPO9/file.txt"
git -C "$REPO9" add file.txt
git -C "$REPO9" commit -q -m "feat(INFRA-123): implement single gap"

out="$(cd "$REPO9" && GITHUB_BASE_REF=main bash "$GUARD" --warn-only 2>&1 || true)"
if echo "$out" | grep -q "no-bundle-PR\|Rule C.*unrelated"; then
    fail "Test 9: single gap ID should PASS Rule C: $out"
else
    pass "Test 9: single gap ID in title passes Rule C"
fi

echo ""
echo "All CREDIBLE-026/CREDIBLE-041 PR scope-honesty checks passed."
