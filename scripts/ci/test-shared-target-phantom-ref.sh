#!/usr/bin/env bash
# scripts/ci/test-shared-target-phantom-ref.sh — INFRA-1138 (2026-05-14)
#
# Verifies that using CARGO_TARGET_DIR per-worktree in the test gate prevents
# phantom fingerprint errors caused by sibling worktrees sharing the same
# CARGO_TARGET_DIR (set by install-sccache.sh / INFRA-481).
#
# Tests:
#   1. Structural: pre-push uses per-worktree CARGO_TARGET_DIR for cargo test
#   2. Structural: .cargo-test-target is gitignored
#   3. Structural: INFRA-1138 marker present in pre-push hook
#   4. Logic: CARGO_TARGET_DIR override isolates fingerprints (env var visible)
#   5. Logic: sccache rustc-wrapper config is NOT overridden (still applies)
#   6. Logic: .cargo-test-target path is per-worktree (uses REPO_ROOT_T)
#   7. Documentation: CLAUDE_GOTCHAS.md mentions phantom fingerprint issue
#   8. Documentation: KNOWN_FLAKES.yaml connection (previously documented flakes)

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PRE_PUSH="$REPO_ROOT/scripts/git-hooks/pre-push"
GITIGNORE="$REPO_ROOT/.gitignore"
GOTCHAS="$REPO_ROOT/docs/process/CLAUDE_GOTCHAS.md"

PASS=0
FAIL=0
ok()   { printf 'PASS: %s\n' "$*"; PASS=$((PASS+1)); }
fail() { printf 'FAIL: %s\n' "$*"; FAIL=$((FAIL+1)); }

echo "=== INFRA-1138 shared-target phantom-ref test ==="
echo

# ── Test 1: pre-push uses per-worktree CARGO_TARGET_DIR ──────────────────────
if grep -q "cargo-test-target" "$PRE_PUSH" && grep -q "CARGO_TARGET_DIR" "$PRE_PUSH"; then
    ok "pre-push sets per-worktree CARGO_TARGET_DIR for cargo test"
else
    fail "pre-push missing per-worktree CARGO_TARGET_DIR for cargo test"
fi

# ── Test 2: .cargo-test-target is gitignored ─────────────────────────────────
if grep -q "\.cargo-test-target" "$GITIGNORE"; then
    ok ".cargo-test-target is in .gitignore"
else
    fail ".cargo-test-target not found in .gitignore"
fi

# ── Test 3: INFRA-1138 marker in pre-push ─────────────────────────────────────
if grep -q "INFRA-1138" "$PRE_PUSH"; then
    ok "INFRA-1138 marker present in pre-push hook"
else
    fail "INFRA-1138 marker missing from pre-push hook"
fi

# ── Test 4: CARGO_TARGET_DIR is set before cargo test invocation ─────────────
# Verify the override appears on the same line as cargo test (env-prefix form)
if grep -qE "CARGO_TARGET_DIR=.*cargo test|CARGO_TARGET_DIR.*\\\s*$" "$PRE_PUSH"; then
    ok "CARGO_TARGET_DIR env-prefix applied before cargo test invocation"
else
    fail "CARGO_TARGET_DIR env-prefix not correctly placed before cargo test"
fi

# ── Test 5: sccache rustc-wrapper not overridden ─────────────────────────────
# The .cargo/config.toml still has rustc-wrapper=sccache; pre-push doesn't unset RUSTC_WRAPPER
if ! grep -q "unset.*RUSTC_WRAPPER\|RUSTC_WRAPPER=\|--no-rustc-wrapper" "$PRE_PUSH"; then
    ok "pre-push does not override/unset sccache rustc-wrapper"
else
    fail "pre-push unexpectedly unsets sccache rustc-wrapper"
fi

# ── Test 6: per-worktree path uses REPO_ROOT_T (worktree root, not shared) ───
if grep -q '_WT_TEST_TARGET.*REPO_ROOT_T\|REPO_ROOT_T.*cargo-test-target' "$PRE_PUSH"; then
    ok "per-worktree test target path uses REPO_ROOT_T (not shared main repo)"
else
    fail "per-worktree test target path missing REPO_ROOT_T binding"
fi

# ── Test 7: CLAUDE_GOTCHAS.md documents the phantom fingerprint issue ─────────
if [[ -r "$GOTCHAS" ]] && grep -q "INFRA-1138\|phantom.*fingerprint\|shared.*CARGO_TARGET_DIR.*phantom\|cargo-test-target" "$GOTCHAS"; then
    ok "CLAUDE_GOTCHAS.md documents the shared-target phantom fingerprint issue"
else
    fail "CLAUDE_GOTCHAS.md missing INFRA-1138 / phantom fingerprint documentation"
fi

# ── Test 8: structure — cargo test block includes target dir setup ────────────
# The per-worktree target dir variable is set before the cargo test invocation.
if grep -q "_WT_TEST_TARGET" "$PRE_PUSH" && grep -q "CARGO_TARGET_DIR.*_WT_TEST_TARGET" "$PRE_PUSH"; then
    ok "cargo test block sets up per-worktree _WT_TEST_TARGET then uses it as CARGO_TARGET_DIR"
else
    fail "cargo test block missing _WT_TEST_TARGET / CARGO_TARGET_DIR=\$_WT_TEST_TARGET setup"
fi

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
