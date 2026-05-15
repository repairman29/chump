#!/usr/bin/env bash
# test-rust-first-worktree-bypass.sh — INFRA-1309
#
# Verifies that pre-commit-rust-first.sh reads COMMIT_EDITMSG from
# --git-common-dir (not --git-dir) so Rust-First-Bypass trailers are
# detected when committing from a linked worktree.
#
# AC:
#   1. Script uses --git-common-dir for MSG_FILE (source assertion)
#   2. Bypass trailer is detected when committing from a linked worktree
#   3. Existing bypass behavior unchanged for main-checkout commits
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HOOK="$REPO_ROOT/scripts/git-hooks/pre-commit-rust-first.sh"

PASS=0; FAIL=0
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

echo "=== INFRA-1309 pre-commit-rust-first linked-worktree bypass ==="
echo

# ── AC-1: Source assertion — uses --git-common-dir ───────────────────────────
echo "--- AC-1: Uses --git-common-dir for COMMIT_EDITMSG ---"

grep -q 'git-common-dir' "$HOOK" \
  && ok "MSG_FILE uses --git-common-dir" \
  || fail "MSG_FILE still uses --git-dir (NOT fixed)"

# Ensure --git-dir is not used for MSG_FILE path
# (allow it in other contexts but not for MSG_FILE assignment)
if grep -n 'MSG_FILE.*git-dir\b' "$HOOK" | grep -v '#' | grep -q .; then
  fail "MSG_FILE still uses --git-dir (un-commented)"
else
  ok "MSG_FILE does not use --git-dir"
fi

grep -q 'INFRA-1309' "$HOOK" \
  && ok "INFRA-1309 change is annotated in hook" \
  || fail "INFRA-1309 annotation missing from hook"

# ── AC-2: Functional — bypass works in a linked worktree ─────────────────────
echo "--- AC-2: Bypass trailer detected in linked worktree ---"

TMPDIR_BASE="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_BASE"' EXIT

# Create a main git repo
MAIN_REPO="$TMPDIR_BASE/main"
mkdir -p "$MAIN_REPO"
cd "$MAIN_REPO"
git init -q
git config user.email "test@test"
git config user.name "Test"
echo "initial" > README.md
git add README.md
git commit -q -m "init"

# Create a linked worktree
LINKED_WT="$TMPDIR_BASE/linked"
git worktree add -q "$LINKED_WT" -b test-branch

# Write a COMMIT_EDITMSG to the COMMON gitdir (where git puts it)
COMMON_GITDIR="$(git rev-parse --git-common-dir)"
echo -e "fix: some change\n\nRust-First-Bypass: test bypass reason" > "$COMMON_GITDIR/COMMIT_EDITMSG"

# Stage a coord file in the linked worktree to trigger the gate
cd "$LINKED_WT"
mkdir -p scripts/coord
cat > scripts/coord/new-coord.sh << 'EOF'
#!/usr/bin/env bash
echo "new coord script"
EOF
git add scripts/coord/new-coord.sh

# Run hook with the common-gitdir COMMIT_EDITMSG
if CHUMP_RUST_FIRST_CHECK=1 bash "$HOOK" 2>/dev/null; then
  ok "Bypass trailer in --git-common-dir/COMMIT_EDITMSG is detected in linked worktree"
else
  fail "Bypass trailer NOT detected in linked worktree (INFRA-1309 regression)"
fi

# ── AC-3: Main-checkout bypass unchanged ─────────────────────────────────────
echo "--- AC-3: Main-checkout bypass still works ---"

cd "$MAIN_REPO"
echo -e "fix: main checkout change\n\nRust-First-Bypass: main checkout test" > "$COMMON_GITDIR/COMMIT_EDITMSG"
mkdir -p scripts/coord
cat > scripts/coord/main-coord.sh << 'EOF'
#!/usr/bin/env bash
echo "main coord script"
EOF
git add scripts/coord/main-coord.sh

if CHUMP_RUST_FIRST_CHECK=1 bash "$HOOK" 2>/dev/null; then
  ok "Bypass trailer still works in main checkout"
else
  fail "Bypass trailer broken in main checkout after INFRA-1309 fix"
fi

# ── Summary ───────────────────────────────────────────────────────────────────
echo
echo "=== Results: ${PASS} passed, ${FAIL} failed ==="
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
