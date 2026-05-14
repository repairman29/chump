#!/usr/bin/env bash
# test-edit-replay.sh — INFRA-1200
#
# Recovery test: edit 3 files in worktree A via chump-edit-wrap.sh, delete
# worktree A, create worktree B, run chump-edit-replay.sh, verify all 3 files
# have the correct content in worktree B.
# shellcheck disable=SC2015  # ok() always exits 0; A && ok || fail is safe here
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WRAP="$REPO_ROOT/scripts/coord/chump-edit-wrap.sh"
REPLAY="$REPO_ROOT/scripts/coord/chump-edit-replay.sh"

PASS=0; FAIL=0
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

echo "=== INFRA-1200 chump-edit-wrap/replay recovery test ==="
echo

# ── Pre-conditions ────────────────────────────────────────────────────────────
[[ -x "$WRAP" ]]   || { echo "FATAL: $WRAP not executable"; exit 2; }
[[ -x "$REPLAY" ]] || { echo "FATAL: $REPLAY not executable"; exit 2; }

# ── Setup: isolated temp directories ─────────────────────────────────────────
TMPBASE="$(mktemp -d)"
trap 'rm -rf "$TMPBASE"' EXIT

PLANS_DIR="$TMPBASE/plans"
WORKTREE_A="$TMPBASE/worktree-a"
WORKTREE_B="$TMPBASE/worktree-b"
TEST_GAP="TEST-EDIT-REPLAY-$$"

mkdir -p "$PLANS_DIR" "$WORKTREE_A/src" "$WORKTREE_A/scripts" "$WORKTREE_B"

# ── Phase 1: edit 3 files in worktree A via chump-edit-wrap.sh ───────────────
echo "--- Phase 1: edit 3 files in worktree A ---"

# File 1: src/foo.rs
TARGET_A1="$WORKTREE_A/src/foo.rs"
printf 'pub fn foo() -> u32 { 42 }\n' | \
    CHUMP_PLANS_DIR="$PLANS_DIR" CHUMP_WORKTREE_ROOT="$WORKTREE_A" "$WRAP" "$TEST_GAP" "$TARGET_A1" 2>/dev/null

[[ -f "$TARGET_A1" ]] \
  && ok "file 1 created at target path" \
  || fail "file 1 NOT created at target path"

grep -q 'pub fn foo' "$TARGET_A1" \
  && ok "file 1 content written correctly" \
  || fail "file 1 content wrong"

# File 2: src/bar.rs
TARGET_A2="$WORKTREE_A/src/bar.rs"
printf 'pub fn bar() -> &'"'"'static str { "hello" }\n' | \
    CHUMP_PLANS_DIR="$PLANS_DIR" CHUMP_WORKTREE_ROOT="$WORKTREE_A" "$WRAP" "$TEST_GAP" "$TARGET_A2" 2>/dev/null

[[ -f "$TARGET_A2" ]] \
  && ok "file 2 created at target path" \
  || fail "file 2 NOT created at target path"

# File 3: scripts/baz.sh
TARGET_A3="$WORKTREE_A/scripts/baz.sh"
printf '#!/usr/bin/env bash\necho baz\n' | \
    CHUMP_PLANS_DIR="$PLANS_DIR" CHUMP_WORKTREE_ROOT="$WORKTREE_A" "$WRAP" "$TEST_GAP" "$TARGET_A3" 2>/dev/null

[[ -f "$TARGET_A3" ]] \
  && ok "file 3 created at target path" \
  || fail "file 3 NOT created at target path"

# 3 patches should exist in plans dir
PATCH_COUNT="$(find "$PLANS_DIR/$TEST_GAP" -name '*.patch' 2>/dev/null | wc -l | tr -d ' ')"
[[ "$PATCH_COUNT" -eq 3 ]] \
  && ok "3 patches saved in .chump-plans/$TEST_GAP" \
  || fail "expected 3 patches, found $PATCH_COUNT"

# ── Phase 2: delete worktree A (simulate /tmp reap) ──────────────────────────
echo "--- Phase 2: delete worktree A (simulate /tmp reap) ---"
rm -rf "$WORKTREE_A"
[[ ! -d "$WORKTREE_A" ]] \
  && ok "worktree A deleted (simulating /tmp reap)" \
  || fail "worktree A still exists"

# ── Phase 3: replay patches into fresh worktree B ────────────────────────────
echo "--- Phase 3: replay into worktree B ---"
CHUMP_PLANS_DIR="$PLANS_DIR" "$REPLAY" "$TEST_GAP" "$WORKTREE_B" 2>/dev/null

# Verify all 3 files exist in worktree B with correct content
TARGET_B1="$WORKTREE_B/src/foo.rs"
[[ -f "$TARGET_B1" ]] \
  && ok "file 1 exists in worktree B after replay" \
  || fail "file 1 NOT found in worktree B"

grep -q 'pub fn foo' "$TARGET_B1" 2>/dev/null \
  && ok "file 1 content correct in worktree B" \
  || fail "file 1 content wrong in worktree B"

TARGET_B2="$WORKTREE_B/src/bar.rs"
grep -q 'pub fn bar' "$TARGET_B2" 2>/dev/null \
  && ok "file 2 content correct in worktree B" \
  || fail "file 2 content wrong in worktree B"

TARGET_B3="$WORKTREE_B/scripts/baz.sh"
grep -q 'echo baz' "$TARGET_B3" 2>/dev/null \
  && ok "file 3 content correct in worktree B" \
  || fail "file 3 content wrong in worktree B"

# ── Phase 4: idempotency — replay again, should skip all ─────────────────────
echo "--- Phase 4: idempotency check ---"
REPLAY_OUT="$(CHUMP_PLANS_DIR="$PLANS_DIR" "$REPLAY" "$TEST_GAP" "$WORKTREE_B" 2>&1 || true)"
echo "$REPLAY_OUT" | grep -q 'SKIP' \
  && ok "replay is idempotent (SKIP logged for already-applied patches)" \
  || fail "replay did not skip already-applied patches"

# ── Source assertions ─────────────────────────────────────────────────────────
echo "--- Source assertions ---"
grep -q 'INFRA-1200' "$WRAP" \
  && ok "INFRA-1200 referenced in chump-edit-wrap.sh" \
  || fail "INFRA-1200 NOT referenced in chump-edit-wrap.sh"

grep -q 'INFRA-1200' "$REPLAY" \
  && ok "INFRA-1200 referenced in chump-edit-replay.sh" \
  || fail "INFRA-1200 NOT referenced in chump-edit-replay.sh"

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
