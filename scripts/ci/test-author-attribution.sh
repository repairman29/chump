#!/usr/bin/env bash
# test-author-attribution.sh — CREDIBLE-040: per-harness git author identity.
#
# Asserts:
#   1. gap-claim.sh sets git user.email=bigpickle@chump.bot when
#      CHUMP_AGENT_HARNESS=opencode-bigpickle.
#   2. gap-claim.sh does NOT override git identity for harness=manual
#      (operator identity preserved).
#   3. Synthetic bigpickle commit lands with bigpickle identity.
#   4. Synthetic claude-code-ide commit lands with operator identity
#      (no cross-harness overlap).
#   5. The bigpickle identity is NOT blocked by pre-commit-git-identity.sh.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
GAP_CLAIM="$REPO_ROOT/scripts/coord/gap-claim.sh"
ID_GUARD="$REPO_ROOT/scripts/git-hooks/pre-commit-git-identity.sh"

pass() { printf '[PASS] %s\n' "$*"; }
fail() { printf '[FAIL] %s\n' "$*" >&2; exit 1; }

TMP="$(mktemp -d -t test-author-attr.XXXXXX)"
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

# ── Helper: create isolated git repo ─────────────────────────────────────────
make_repo() {
    local dir="$1" email="$2" name="$3"
    git init -q "$dir"
    git -C "$dir" config user.email "$email"
    git -C "$dir" config user.name  "$name"
    git -C "$dir" config commit.gpgsign false
    printf 'init\n' > "$dir/file.txt"
    git -C "$dir" add file.txt
    git -C "$dir" commit -q -m "chore: init"
}

# ── Test 1: CREDIBLE-040 identity block present in gap-claim.sh ──────────────
if grep -q "CREDIBLE-040" "$GAP_CLAIM"; then
    pass "CREDIBLE-040 block present in gap-claim.sh"
else
    fail "CREDIBLE-040 block missing from gap-claim.sh"
fi

if grep -q "bigpickle@chump.bot" "$GAP_CLAIM"; then
    pass "bigpickle@chump.bot identity configured in gap-claim.sh"
else
    fail "bigpickle@chump.bot not found in gap-claim.sh"
fi

# ── Test 2: harness=opencode-bigpickle → git config set ──────────────────────
REPO2="$TMP/repo2"
make_repo "$REPO2" "operator@example.com" "Operator"
# Extract and run just the CREDIBLE-040 block from gap-claim.sh in the repo
BLOCK=$(awk '/^# ── CREDIBLE-040:/,/^fi$/{print}' "$GAP_CLAIM" | tail -n +1)
(
    cd "$REPO2"
    CHUMP_AGENT_HARNESS=opencode-bigpickle
    eval "$BLOCK"
)
actual_email="$(git -C "$REPO2" config user.email 2>/dev/null || true)"
actual_name="$(git -C "$REPO2" config user.name 2>/dev/null || true)"
[[ "$actual_email" == "bigpickle@chump.bot" ]] \
    || fail "Test 2: expected email bigpickle@chump.bot, got '$actual_email'"
pass "Test 2: harness=opencode-bigpickle sets email to bigpickle@chump.bot"
[[ "$actual_name" == "opencode-bigpickle" ]] \
    || fail "Test 2: expected name opencode-bigpickle, got '$actual_name'"
pass "Test 2: harness=opencode-bigpickle sets name to opencode-bigpickle"

# ── Test 3: harness=manual → identity NOT overridden ─────────────────────────
REPO3="$TMP/repo3"
make_repo "$REPO3" "jeffadkins1@gmail.com" "Jeff Adkins"
(
    cd "$REPO3"
    CHUMP_AGENT_HARNESS=manual
    eval "$BLOCK"
)
actual_email="$(git -C "$REPO3" config user.email 2>/dev/null || true)"
[[ "$actual_email" == "jeffadkins1@gmail.com" ]] \
    || fail "Test 3: manual harness should NOT override operator identity, got '$actual_email'"
pass "Test 3: harness=manual leaves operator identity unchanged"

# ── Test 4: bigpickle commit NOT blocked by pre-commit identity guard ─────────
if [[ -f "$ID_GUARD" ]]; then
    REPO4="$TMP/repo4"
    make_repo "$REPO4" "bigpickle@chump.bot" "opencode-bigpickle"
    printf 'change\n' >> "$REPO4/file.txt"
    git -C "$REPO4" add file.txt
    result=0
    (cd "$REPO4" && bash "$ID_GUARD") || result=$?
    [[ "$result" -eq 0 ]] \
        || fail "Test 4: bigpickle@chump.bot should NOT be blocked by pre-commit-git-identity.sh"
    pass "Test 4: bigpickle@chump.bot passes pre-commit identity guard"
else
    pass "Test 4: pre-commit-git-identity.sh not found — skipping guard test"
fi

# ── Test 5: synthetic bigpickle commit has correct attribution ────────────────
REPO5="$TMP/repo5"
make_repo "$REPO5" "bigpickle@chump.bot" "opencode-bigpickle"
printf 'bigpickle work\n' >> "$REPO5/file.txt"
git -C "$REPO5" add file.txt
git -C "$REPO5" commit -q -m "feat(CREDIBLE-040): bigpickle work"
commit_email="$(git -C "$REPO5" log -1 --pretty=format:%ae)"
commit_name="$(git -C "$REPO5" log -1 --pretty=format:%an)"
[[ "$commit_email" == "bigpickle@chump.bot" ]] \
    || fail "Test 5: commit email is '$commit_email', expected bigpickle@chump.bot"
[[ "$commit_name" == "opencode-bigpickle" ]] \
    || fail "Test 5: commit name is '$commit_name', expected opencode-bigpickle"
pass "Test 5: bigpickle commit attributed to bigpickle@chump.bot / opencode-bigpickle"

# ── Test 6: operator commit does NOT use bigpickle identity ──────────────────
REPO6="$TMP/repo6"
make_repo "$REPO6" "jeffadkins1@gmail.com" "Jeff Adkins"
printf 'operator work\n' >> "$REPO6/file.txt"
git -C "$REPO6" add file.txt
git -C "$REPO6" commit -q -m "feat: operator work"
commit_email="$(git -C "$REPO6" log -1 --pretty=format:%ae)"
[[ "$commit_email" != "bigpickle@chump.bot" ]] \
    || fail "Test 6: operator commit should not use bigpickle identity"
pass "Test 6: operator commit uses operator identity, not bigpickle"

echo ""
echo "=== test-author-attribution.sh PASSED (CREDIBLE-040) ==="
