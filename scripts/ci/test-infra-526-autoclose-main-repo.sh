#!/usr/bin/env bash
# test-infra-526-autoclose-main-repo.sh — INFRA-526
#
# Validates that the bot-merge.sh auto-close path targets the main repo's
# state.db (via $MAIN_REPO) rather than a potentially-wrong inline computation.
#
# Tests:
#   1. repo-paths.sh sets MAIN_REPO to the git-common-dir parent (not worktree)
#   2. bot-merge.sh auto-close block uses $MAIN_REPO (not a stale recomputation)
#   3. chump_with_doctor honours CHUMP_BINARY env var

set -euo pipefail

PASS=0
FAIL=0
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

REPO_ROOT="$(git rev-parse --show-toplevel)"
REPO_PATHS="$REPO_ROOT/scripts/lib/repo-paths.sh"
BOT_MERGE="$REPO_ROOT/scripts/coord/bot-merge.sh"

echo "=== INFRA-526 auto-close main-repo resolution test ==="
echo

# ── Test 1: repo-paths.sh computes MAIN_REPO ─────────────────────────────────
if [[ -f "$REPO_PATHS" ]]; then
    ok "repo-paths.sh exists"
    # shellcheck source=../../scripts/lib/repo-paths.sh
    source "$REPO_PATHS"
    if [[ -n "${MAIN_REPO:-}" ]]; then
        ok "MAIN_REPO is set after sourcing repo-paths.sh: $MAIN_REPO"
        if [[ -d "$MAIN_REPO/.chump" ]]; then
            ok "MAIN_REPO/.chump directory exists (state.db will be found)"
        else
            fail "MAIN_REPO/.chump not found at $MAIN_REPO — state.db would be missing"
        fi
        if [[ -f "$MAIN_REPO/.chump/state.db" ]]; then
            ok "state.db exists at $MAIN_REPO/.chump/state.db"
        else
            fail "state.db not found at $MAIN_REPO/.chump/state.db"
        fi
    else
        fail "MAIN_REPO is empty after sourcing repo-paths.sh"
    fi
else
    fail "repo-paths.sh not found at $REPO_PATHS"
fi

# ── Test 2: bot-merge.sh uses MAIN_REPO for auto-close (not stale recompute) ─
if [[ -f "$BOT_MERGE" ]]; then
    ok "bot-merge.sh exists"
    # The old buggy pattern was an assignment like:
    #   _autoclose_main_repo=$(... | xargs -I{} realpath ...)
    # Check that no live assignment uses this pattern (comments are OK).
    if grep -E '^\s*_autoclose_main_repo=.*xargs' "$BOT_MERGE"; then
        fail "bot-merge.sh still assigns _autoclose_main_repo via xargs+realpath (INFRA-526 fix not applied)"
    else
        ok "fragile xargs+realpath assignment is gone from auto-close block"
    fi
    # The new pattern: use \$MAIN_REPO
    if grep -q '_autoclose_main_repo=.*MAIN_REPO' "$BOT_MERGE"; then
        ok "auto-close block uses \$MAIN_REPO for _autoclose_main_repo"
    else
        fail "auto-close block does not use \$MAIN_REPO — INFRA-526 fix may be missing"
    fi
else
    fail "bot-merge.sh not found at $BOT_MERGE"
fi

# ── Test 3: chump_with_doctor honours CHUMP_BINARY ───────────────────────────
if [[ -f "$BOT_MERGE" ]]; then
    if grep -q 'CHUMP_BINARY' "$BOT_MERGE" && grep -q '_chump_bin.*CHUMP_BINARY' "$BOT_MERGE"; then
        ok "chump_with_doctor honours CHUMP_BINARY env var"
    else
        fail "chump_with_doctor does not honour CHUMP_BINARY — binary pinning not in place"
    fi
    if grep -q '~/.cargo/bin/chump\|HOME.*\.cargo.*chump' "$BOT_MERGE"; then
        ok "auto-close block tries to pin to ~/.cargo/bin/chump"
    else
        fail "auto-close block does not pin to ~/.cargo/bin/chump"
    fi
fi

# ── Test 4: MAIN_REPO is not the worktree when called from a linked worktree ──
_common_dir="$(git rev-parse --git-common-dir 2>/dev/null || echo '.git')"
if [[ "$_common_dir" != ".git" ]]; then
    # We are in a linked worktree — MAIN_REPO should differ from REPO_ROOT
    if [[ "${MAIN_REPO:-}" != "${REPO_ROOT:-}" ]]; then
        ok "MAIN_REPO ($MAIN_REPO) differs from REPO_ROOT ($REPO_ROOT) — linked worktree correctly resolved"
    else
        fail "MAIN_REPO == REPO_ROOT in a linked worktree — state.db targeting would be wrong"
    fi
else
    ok "running in main checkout; MAIN_REPO == REPO_ROOT is expected"
fi

echo
echo "Results: $PASS passed, $FAIL failed"
if [[ $FAIL -gt 0 ]]; then
    exit 1
fi
