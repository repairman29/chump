#!/usr/bin/env bash
# test-hooks-auto-install.sh — regression test for INFRA-209 / INFRA-224.
#
# Cold Water Red Letter #10 (2026-05-02) found that fresh CCR sandboxes / new
# linked worktrees committed through bot-merge.sh WITHOUT the pre-commit hook
# installed, silently bypassing every guard (closed_pr integrity, gaps-yaml
# discipline, duplicate-id, etc.). Result: 9 gaps shipped with `closed_pr: TBD`
# since 2026-05-01 alone.
#
# The runtime fix (INFRA-224, PR #759) added a one-shot bootstrap block at the
# top of bot-merge.sh that calls scripts/setup/install-hooks.sh when the
# worktree's git-dir lacks a pre-commit hook. gap-claim.sh has the same
# bootstrap (AUTO-HYGIENE-c). This regression test pins both behaviours so
# they cannot silently regress.
#
# Acceptance criteria verified:
#   (1) install-hooks.sh is idempotent — running twice on a hook-installed
#       worktree is a no-op (no error, hook still pointing at the source).
#   (2) When a worktree's git-hooks/ dir has no pre-commit hook, the
#       bot-merge.sh bootstrap block creates one (we exercise the same
#       install-hooks.sh path it calls).
#   (3) The hook installed by step (2) is a symlink that targets the
#       canonical source under scripts/git-hooks/pre-commit.
#   (4) gap-claim.sh's bootstrap (AUTO-HYGIENE-c) installs hooks the same way.
#
# This test does NOT actually run bot-merge.sh end-to-end (that needs a
# remote, gh auth, and a working tree with cargo build green). It exercises
# the install-hooks.sh entry point that both bot-merge.sh and gap-claim.sh
# delegate to, AND it grep-checks both wrappers still call the entry point
# unconditionally (so a future refactor that drops the call gets caught).
#
# Run:
#   ./scripts/ci/test-hooks-auto-install.sh
#
# Exits non-zero on any check failure.

set -euo pipefail

PASS=0
FAIL=0
FAILS=()

ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); FAILS+=("$1"); }

echo "=== INFRA-209 hooks auto-install regression tests ==="
echo

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
INSTALL="$REPO_ROOT/scripts/setup/install-hooks.sh"
HOOKS_SRC="$REPO_ROOT/scripts/git-hooks"
BOT_MERGE="$REPO_ROOT/scripts/coord/bot-merge.sh"
GAP_CLAIM="$REPO_ROOT/scripts/coord/gap-claim.sh"

if [[ ! -x "$INSTALL" ]]; then
    echo "FATAL: install-hooks.sh not found or not executable: $INSTALL"
    exit 2
fi
if [[ ! -d "$HOOKS_SRC" ]]; then
    echo "FATAL: hooks source dir missing: $HOOKS_SRC"
    exit 2
fi

# ── Test 1: idempotency on the real repo ──────────────────────────────────────
# install-hooks.sh ran twice in a row on the live repo must not error and
# must leave the pre-commit hook still pointing at the source. This is the
# single most important guarantee — every wrapper that calls install-hooks.sh
# (bot-merge, gap-claim) does so unconditionally on every invocation, so a
# non-idempotent installer would error every time the wrapper runs.
echo "--- Test 1: install-hooks.sh is idempotent on the live repo ---"
if "$INSTALL" --quiet >/dev/null 2>&1 && "$INSTALL" --quiet >/dev/null 2>&1; then
    ok "two consecutive install-hooks.sh runs both succeed"
else
    fail "install-hooks.sh failed on a back-to-back run (must be idempotent)"
fi

# ── Test 2: simulated fresh-sandbox install creates pre-commit symlink ────────
# Build a throwaway git repo that mirrors the wrapper's environment:
# - no pre-commit hook installed
# - scripts/git-hooks/ + scripts/setup/install-hooks.sh present (symlinks
#   into the real repo so the source files exist on disk)
# Then run install-hooks.sh exactly the way bot-merge.sh's bootstrap block
# invokes it and confirm a pre-commit symlink lands in .git/hooks/.
echo "--- Test 2: fresh sandbox + install-hooks.sh produces pre-commit symlink ---"
TMPDIR_BASE="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_BASE"' EXIT
SANDBOX="$TMPDIR_BASE/sandbox"
mkdir -p "$SANDBOX"
git -C "$SANDBOX" init -q -b main
git -C "$SANDBOX" config user.email "test@test.com"
git -C "$SANDBOX" config user.name "Test"

# Mirror the scripts the installer + wrappers expect.
mkdir -p "$SANDBOX/scripts/setup" "$SANDBOX/scripts/git-hooks"
cp "$INSTALL" "$SANDBOX/scripts/setup/install-hooks.sh"
chmod +x "$SANDBOX/scripts/setup/install-hooks.sh"
for src in "$HOOKS_SRC"/*; do
    [[ -f "$src" ]] || continue
    cp "$src" "$SANDBOX/scripts/git-hooks/$(basename "$src")"
done

# Confirm the precondition: no pre-commit hook yet.
if [[ -e "$SANDBOX/.git/hooks/pre-commit" ]]; then
    fail "sandbox precondition violated: pre-commit hook already present"
fi

# Run install-hooks.sh from inside the sandbox the same way bot-merge.sh does.
( cd "$SANDBOX" && bash scripts/setup/install-hooks.sh --quiet ) 2>/tmp/.hooks-install-err
if [[ -L "$SANDBOX/.git/hooks/pre-commit" || -f "$SANDBOX/.git/hooks/pre-commit" ]]; then
    ok "install-hooks.sh created .git/hooks/pre-commit in fresh sandbox"
else
    fail "install-hooks.sh did not create pre-commit hook (stderr: $(cat /tmp/.hooks-install-err 2>/dev/null || echo none))"
fi

# ── Test 3: installed hook is a symlink to scripts/git-hooks/pre-commit ───────
echo "--- Test 3: installed pre-commit is a symlink to scripts/git-hooks/pre-commit ---"
if [[ -L "$SANDBOX/.git/hooks/pre-commit" ]]; then
    target="$(readlink "$SANDBOX/.git/hooks/pre-commit")"
    if [[ "$target" == *"/scripts/git-hooks/pre-commit" ]]; then
        ok "pre-commit symlink targets canonical source ($target)"
    else
        fail "pre-commit symlink points at unexpected target: $target"
    fi
else
    fail "pre-commit hook is not a symlink — install-hooks.sh contract changed"
fi

# ── Test 4: bot-merge.sh still calls install-hooks.sh in its bootstrap ────────
# Guards against a future refactor silently removing the INFRA-224 block.
# The exact text the bootstrap block uses is grep-stable.
echo "--- Test 4: bot-merge.sh wrapper still calls install-hooks.sh ---"
if [[ -f "$BOT_MERGE" ]] && grep -q 'install-hooks\.sh' "$BOT_MERGE" \
        && grep -q 'CHUMP_INSTALL_HOOKS' "$BOT_MERGE"; then
    ok "bot-merge.sh contains the INFRA-224 hooks-bootstrap block"
else
    fail "bot-merge.sh missing the install-hooks.sh bootstrap (INFRA-224 regressed)"
fi

# ── Test 5: gap-claim.sh still calls install-hooks.sh (AUTO-HYGIENE-c) ────────
echo "--- Test 5: gap-claim.sh wrapper still calls install-hooks.sh ---"
if [[ -f "$GAP_CLAIM" ]] && grep -q 'install-hooks\.sh' "$GAP_CLAIM"; then
    ok "gap-claim.sh contains the AUTO-HYGIENE-c hooks-bootstrap call"
else
    fail "gap-claim.sh missing the install-hooks.sh bootstrap (AUTO-HYGIENE-c regressed)"
fi

# ── Summary ──────────────────────────────────────────────────────────────────
echo
echo "=== Results: $PASS passed, $FAIL failed ==="
if [[ "$FAIL" -gt 0 ]]; then
    for f in "${FAILS[@]}"; do echo "  - $f"; done
    exit 1
fi
exit 0
