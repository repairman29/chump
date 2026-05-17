#!/usr/bin/env bash
# test-pre-push-hook-no-sigpipe.sh — INFRA-1588 regression test.
#
# Verifies that the pre-push hook no longer exits 141 (SIGPIPE) silently
# when its internal `git worktree list | awk … exit` pipeline runs under
# `set -o pipefail`. Today's 4 silent-abort ships (#2250, #2251, #2252,
# #2254) all hit that exact pattern.
#
# Strategy: build a throwaway repo, copy the hook into it, fabricate a
# minimal HEAD commit + a Bot-Merge-Bypass trailer (forces the hook down
# the code path that contains the formerly-failing pipeline), invoke the
# hook directly with the stub-env that lets it short-circuit before any
# real network calls, and assert:
#   1. exit code is NOT 141 (SIGPIPE),
#   2. stdout/stderr contain the expected progress markers — i.e. the
#      hook actually ran the bypass branch rather than aborting silently,
#   3. when we deliberately inject an error after the hook's strict-mode
#      setup, the ERR trap surfaces the line+exit instead of failing mute.

set -euo pipefail

PASS=0; FAIL=0; FAILS=()
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); FAILS+=("$1"); }

echo "=== INFRA-1588 pre-push hook SIGPIPE regression ==="
echo

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
HOOK_SRC="$REPO_ROOT/scripts/git-hooks/pre-push"

if [ ! -f "$HOOK_SRC" ]; then
    echo "FATAL: hook source missing at $HOOK_SRC"
    exit 2
fi

TMPDIR_BASE="$(mktemp -d -t infra1588.XXXXXX)"
trap 'rm -rf "$TMPDIR_BASE"' EXIT

# ---------- Test 1: hook does NOT exit 141 under pipefail ----------------
TR1="$TMPDIR_BASE/repo1"
mkdir -p "$TR1"
(
    cd "$TR1"
    git init -q -b main
    git config user.email "test@example.com"
    git config user.name "Test"
    # Build the bypass-trailer commit body.
    echo "seed" > a
    git add a
    git commit -q --no-verify -m "fix(INFRA-1588): seed

Bot-Merge-Bypass: regression test for SIGPIPE bug
"
)
cp "$HOOK_SRC" "$TR1/.git/hooks/pre-push"
chmod +x "$TR1/.git/hooks/pre-push"

# stdin format for git's pre-push hook: local_ref local_sha remote_ref remote_sha
# Use HEAD as both local_sha and (synthetic) remote_sha=0 to mimic a first push.
local_sha=$(cd "$TR1" && git rev-parse HEAD)
hook_input="refs/heads/chump/infra-1588-test $local_sha refs/heads/chump/infra-1588-test 0000000000000000000000000000000000000000"

# Stub envs:
#   CHUMP_BYPASS_BOT_MERGE=1 + Bot-Merge-Bypass trailer → hits the worktree-list block.
#   CHUMP_GAP_CHECK=0 / CHUMP_MERGE_PREVIEW=0 / CHUMP_FMT_CHECK=0 →
#     skip slow + network-bound guards.
#   CHUMP_FIXTURE_AUTHOR_GUARD=0 → skip ghost-commit scan.
#   CHUMP_CI_REGRESSION_GUARD=0 → skip downstream guard script.
set +e
out=$(cd "$TR1" && \
    CHUMP_BYPASS_BOT_MERGE=1 \
    CHUMP_GAP_CHECK=0 \
    CHUMP_MERGE_PREVIEW=0 \
    CHUMP_FMT_CHECK=0 \
    CHUMP_FIXTURE_AUTHOR_GUARD=0 \
    CHUMP_CI_REGRESSION_GUARD=0 \
    CHUMP_CLIPPY_GATE=0 \
    CHUMP_TEST_GATE=0 \
    CHUMP_FORCE_LEASE_CHECK=0 \
    CHUMP_REBASE_DETECT=0 \
    bash .git/hooks/pre-push origin "git@example.com:fake/repo" <<<"$hook_input" 2>&1)
rc=$?
set -e

if [ "$rc" = "141" ]; then
    fail "Test 1: hook exited 141 (SIGPIPE) — the bug is still live"
    echo "----- captured output -----"
    echo "$out"
    echo "---------------------------"
else
    ok "Test 1: hook did NOT exit 141 (got $rc)"
fi

# The bypass-audit code path must have actually executed (proves we reached
# the previously-failing line). The hook emits a "[pre-push] INFRA-1441:"
# diagnostic message right after the worktree-list section.
if grep -q "INFRA-1441: bot-merge bypass authorized" <<<"$out"; then
    ok "Test 2: bypass-audit message present (worktree-list block ran)"
else
    fail "Test 2: bypass-audit message missing — hook may have aborted silently"
    echo "----- captured output -----"
    echo "$out"
    echo "---------------------------"
fi

# ---------- Test 3: ERR trap surfaces line+exit -------------------------
# Build a minimal harness that mirrors the hook's strict-mode preamble +
# trap. If a downstream command fails, the trap MUST print line+exit to
# stderr. This guards against the trap being deleted or moved above
# `set -e` (where it would not fire).
trap_test=$(bash -c '
set -euo pipefail
trap '"'"'rc=$?; echo "[pre-push] hook aborted at line $LINENO with exit $rc" >&2; exit $rc'"'"' ERR
false  # forces ERR
echo "should not reach here"
' 2>&1) || true

if grep -q "hook aborted at line .* with exit" <<<"$trap_test"; then
    ok "Test 3: ERR trap surfaces line+exit on failure"
else
    fail "Test 3: ERR trap did not fire — silent-abort mode still possible"
    echo "----- captured output -----"
    echo "$trap_test"
    echo "---------------------------"
fi

# ---------- Test 4: hook source has the trap installed ------------------
if grep -qE "^trap '.*hook aborted at line.*ERR" "$HOOK_SRC"; then
    ok "Test 4: ERR trap is wired into the live hook source"
else
    fail "Test 4: ERR trap missing from $HOOK_SRC — silent-abort can reoccur"
fi

# ---------- Test 5: SIGPIPE-prone pipeline removed ----------------------
if grep -vE '^[[:space:]]*#' "$HOOK_SRC" \
        | grep -qE "git worktree list --porcelain.*\| awk.*exit"; then
    fail "Test 5: SIGPIPE-prone 'git worktree list | awk …exit' pattern still present (in live code)"
else
    ok "Test 5: SIGPIPE-prone worktree-list pipeline refactored (only historical comments remain)"
fi

echo
echo "Passed: $PASS"
echo "Failed: $FAIL"
if [ "$FAIL" -gt 0 ]; then
    printf '  - %s\n' "${FAILS[@]}"
    exit 1
fi
exit 0
