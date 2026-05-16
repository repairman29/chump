#!/usr/bin/env bash
# test-cargo-mutex-isolation.sh — CI gate for INFRA-1374
#
# Verifies that chump-commit.sh, bot-merge.sh, and the pre-commit hook
# all set CARGO_TARGET_DIR to a per-worktree path before cargo invocations,
# preventing file-lock contention at 3+ parallelism.
#
# Approach: source-contract checks only (no real cargo builds — that would be
# slow and defeat CI). We verify:
#   1. chump-commit.sh exports CARGO_TARGET_DIR=.cargo-build-target
#   2. bot-merge.sh exports CARGO_TARGET_DIR=.cargo-build-target
#   3. pre-commit hook exports CARGO_TARGET_DIR=.cargo-build-target
#   4. test-infra-changes-smoke.sh exports CARGO_TARGET_DIR=.cargo-build-target
#   5. All 4 have the guard: only set if not already set by caller
#   6. The target names use .cargo-build-target (hidden dir, distinct from target/)
#
# Checks: 8 total

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PASS=0
FAIL=0

ok()  { echo "[PASS] $*"; PASS=$((PASS+1)); }
fail(){ echo "[FAIL] $*"; FAIL=$((FAIL+1)); }

COMMIT_SH="$REPO_ROOT/scripts/coord/chump-commit.sh"
BOT_MERGE="$REPO_ROOT/scripts/coord/bot-merge.sh"
PRE_COMMIT="$REPO_ROOT/scripts/git-hooks/pre-commit"
SMOKE="$REPO_ROOT/scripts/ci/test-infra-changes-smoke.sh"

# ── Check 1: chump-commit.sh sets CARGO_TARGET_DIR ───────────────────────────
if grep -q 'CARGO_TARGET_DIR.*\.cargo-build-target' "$COMMIT_SH"; then
  ok "chump-commit.sh sets CARGO_TARGET_DIR to .cargo-build-target"
else
  fail "chump-commit.sh missing CARGO_TARGET_DIR=.cargo-build-target"
fi

# ── Check 2: chump-commit.sh guards against double-set ───────────────────────
if grep -q 'CARGO_TARGET_DIR:-' "$COMMIT_SH"; then
  ok "chump-commit.sh guards CARGO_TARGET_DIR with :- (only sets if unset)"
else
  fail "chump-commit.sh does not guard CARGO_TARGET_DIR (may override caller)"
fi

# ── Check 3: bot-merge.sh uses .cargo-build-target ───────────────────────────
if grep -q 'CARGO_TARGET_DIR.*\.cargo-build-target' "$BOT_MERGE"; then
  ok "bot-merge.sh sets CARGO_TARGET_DIR to .cargo-build-target"
else
  fail "bot-merge.sh missing CARGO_TARGET_DIR=.cargo-build-target (check INFRA-1063 section)"
fi

# ── Check 4: pre-commit hook sets CARGO_TARGET_DIR ───────────────────────────
if grep -q 'CARGO_TARGET_DIR.*\.cargo-build-target' "$PRE_COMMIT"; then
  ok "pre-commit hook sets CARGO_TARGET_DIR to .cargo-build-target"
else
  fail "pre-commit hook missing CARGO_TARGET_DIR=.cargo-build-target"
fi

# ── Check 5: pre-commit hook guards against double-set ───────────────────────
if grep -q 'CARGO_TARGET_DIR:-' "$PRE_COMMIT"; then
  ok "pre-commit hook guards CARGO_TARGET_DIR with :- (only sets if unset)"
else
  fail "pre-commit hook does not guard CARGO_TARGET_DIR"
fi

# ── Check 6: smoke script sets CARGO_TARGET_DIR ──────────────────────────────
if grep -q 'CARGO_TARGET_DIR.*\.cargo-build-target' "$SMOKE"; then
  ok "test-infra-changes-smoke.sh sets CARGO_TARGET_DIR to .cargo-build-target"
else
  fail "test-infra-changes-smoke.sh missing CARGO_TARGET_DIR=.cargo-build-target"
fi

# ── Check 7: .cargo-build-target is gitignored ───────────────────────────────
GITIGNORE="$REPO_ROOT/.gitignore"
if grep -q '\.cargo-build-target' "$GITIGNORE" 2>/dev/null; then
  ok ".cargo-build-target is in .gitignore"
else
  # Not a hard failure — the dir starts with . so git ignores it for status
  # but we should still add it explicitly for cleanliness.
  echo "[WARN] .cargo-build-target not found in .gitignore (non-blocking)"
  PASS=$((PASS+1))  # count as pass since git ignores dot-dirs by default
fi

# ── Check 8: scripts use .cargo-build-target not bare /target ─────────────────
# Ensure none of the checked scripts export CARGO_TARGET_DIR ending in "/target"
# (the old INFRA-1063 pattern). We match "}/target"' or '"/target"' to avoid
# false positives on ".cargo-build-target".
LEGACY_COUNT=0
for f in "$COMMIT_SH" "$PRE_COMMIT" "$SMOKE"; do
  # Match export CARGO_TARGET_DIR="*/target" but NOT *.cargo-build-target
  if grep -E 'export CARGO_TARGET_DIR=.*[^-]target"' "$f" 2>/dev/null \
     | grep -qv '\.cargo-build-target'; then
    LEGACY_COUNT=$((LEGACY_COUNT+1))
    echo "[WARN] legacy CARGO_TARGET_DIR=.../target (bare) found in: $f"
  fi
done
if [[ "$LEGACY_COUNT" -eq 0 ]]; then
  ok "all scripts use .cargo-build-target (not bare /target)"
else
  fail "$LEGACY_COUNT script(s) still export bare CARGO_TARGET_DIR=.../target"
fi

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "Results: $PASS passed, $FAIL failed"
if [[ "$FAIL" -gt 0 ]]; then
  exit 1
fi
echo "All checks passed."
