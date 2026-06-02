#!/usr/bin/env bash
# test-no-manual-ship-bypass.sh — INFRA-719 smoke tests.
#
# Verifies pre-push Guard 4 (bot-merge required for new gap branches):
#   1. Direct push of chump/<gap-id>-* new branch → exit 1 (blocked)
#   2. CHUMP_BYPASS_BOT_MERGE=1 → exit 0 (bypass works)
#   3. CHUMP_BOT_MERGE_IN_PROGRESS=1 → exit 0 (bot-merge path)
#   4. Non-gap branch (feature/foo) → exit 0 (not a gap branch)
#   5. Existing branch push (remote_sha != zeros) → exit 0 (update, not new PR)
#
# The hook is invoked as: bash pre-push <remote_name> <remote_url>
# stdin format (per git): "<local_ref> <local_sha> <remote_ref> <remote_sha>"

set -euo pipefail

# Derive REPO_ROOT from this script's location; avoids git rev-parse issues
# in linked worktrees on macOS where /tmp is symlinked to /private/tmp.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
HOOK="$REPO_ROOT/scripts/git-hooks/pre-push"

if [[ ! -x "$HOOK" ]]; then
    echo "[FAIL] $HOOK not executable"
    exit 1
fi

PASS=0
FAIL=0

# Any non-zero sha used as a stand-in for "existing remote tip".
NONZERO_SHA="aabbccddeeff00112233445566778899aabbccdd"
ZERO_SHA="0000000000000000000000000000000000000000"
LOCAL_SHA="$(GIT_WORK_TREE="$REPO_ROOT" git -C "$REPO_ROOT" rev-parse HEAD 2>/dev/null || echo 'deadbeefdeadbeefdeadbeefdeadbeefdeadbeef')"

# INFRA-2097: synthetic commit SHA with NO Bot-Merge-Bypass trailer.
# Real HEAD's commit message may legitimately contain the trailer (from manual
# recovery PRs); Test 2 verifies the no-trailer-blocked path, so it MUST use a
# commit with no trailer. git commit-tree creates a detached commit object —
# no ref updated, no working tree touch.
LOCAL_SHA_NO_TRAILER="$(GIT_WORK_TREE="$REPO_ROOT" \
    GIT_AUTHOR_NAME="Test Fixture" GIT_AUTHOR_EMAIL="fixture@test.local" \
    GIT_COMMITTER_NAME="Test Fixture" GIT_COMMITTER_EMAIL="fixture@test.local" \
    git -C "$REPO_ROOT" commit-tree 'HEAD^{tree}' -m 'fixture: no-trailer commit for infra-1441 test' 2>/dev/null \
    || echo "$LOCAL_SHA")"

run_hook() {
    local env_line="$1"       # extra env vars (KEY=val space-separated)
    local remote_sha="$2"     # remote sha (zeros = new branch)
    local branch="$3"         # branch name
    local local_sha_override="${4:-$LOCAL_SHA}"  # INFRA-2097: Test 2 passes LOCAL_SHA_NO_TRAILER
    local stdin_line
    stdin_line="refs/heads/$branch $local_sha_override refs/heads/$branch $remote_sha"

    # Build env prefix
    local env_cmd=""
    [[ -n "$env_line" ]] && env_cmd="$env_line"

    # Run hook with custom env, remote = 'origin' (no live gh call needed for
    # new-branch pushes — guard fires before gh is touched).
    # CHUMP_BYPASS_TRAILER_CHECK=0: this test exercises Guard 4 (bot-merge required)
    # not the bypass-trailer validator (INFRA-2407). The fixture commit message must
    # not trigger the bypass-trailer sub-hook as a false positive.
    set +e
    echo "$stdin_line" | env \
        CHUMP_GAP_CHECK=0 \
        CHUMP_FMT_CHECK=0 \
        CHUMP_TEST_GATE=0 \
        CHUMP_FORCE_LEASE_CHECK=0 \
        CHUMP_AUTOMERGE_OVERRIDE=1 \
        CHUMP_REBASE_DETECT=0 \
        CHUMP_BYPASS_TRAILER_CHECK=0 \
        $env_cmd \
        bash "$HOOK" origin "git@github.com:example/repo.git" 2>/dev/null
    local rc=$?
    set -e
    echo $rc
}

# ── Test 1: new gap branch without bot-merge → blocked ───────────────────────
echo "Test 1: direct new-branch push of chump/infra-999-claim → exit 1"
rc=$(run_hook "" "$ZERO_SHA" "chump/infra-999-claim")
if [[ "$rc" -eq 1 ]]; then
    echo "[PASS] blocked as expected"
    PASS=$((PASS + 1))
else
    echo "[FAIL] expected exit 1, got $rc"
    FAIL=$((FAIL + 1))
fi

# ── Test 2: CHUMP_BYPASS_BOT_MERGE=1 without trailer → blocked (INFRA-1441) ──
# INFRA-1441: CHUMP_BYPASS_BOT_MERGE=1 alone is no longer sufficient;
# the HEAD commit must also carry a `Bot-Merge-Bypass: <reason>` trailer.
# Current HEAD commit does not have that trailer, so exit 1 is expected.
echo ""
echo "Test 2: CHUMP_BYPASS_BOT_MERGE=1 (no trailer) → exit 1 (INFRA-1441: trailer required)"
# INFRA-2097: pass synthetic no-trailer SHA so test works regardless of real HEAD state
rc=$(run_hook "CHUMP_BYPASS_BOT_MERGE=1" "$ZERO_SHA" "chump/infra-999-claim" "$LOCAL_SHA_NO_TRAILER")
if [[ "$rc" -eq 1 ]]; then
    echo "[PASS] blocked as expected (trailer missing)"
    PASS=$((PASS + 1))
else
    echo "[FAIL] expected exit 1 (trailer required), got $rc"
    FAIL=$((FAIL + 1))
fi

# ── Test 3: CHUMP_BOT_MERGE_IN_PROGRESS=1 → allowed ─────────────────────────
echo ""
echo "Test 3: CHUMP_BOT_MERGE_IN_PROGRESS=1 → exit 0 (bot-merge path)"
rc=$(run_hook "CHUMP_BOT_MERGE_IN_PROGRESS=1" "$ZERO_SHA" "chump/infra-999-claim")
if [[ "$rc" -eq 0 ]]; then
    echo "[PASS] bot-merge path accepted"
    PASS=$((PASS + 1))
else
    echo "[FAIL] expected exit 0, got $rc"
    FAIL=$((FAIL + 1))
fi

# ── Test 4: non-gap branch → allowed ─────────────────────────────────────────
echo ""
echo "Test 4: non-gap branch feature/my-feature → exit 0"
rc=$(run_hook "" "$ZERO_SHA" "feature/my-feature")
if [[ "$rc" -eq 0 ]]; then
    echo "[PASS] non-gap branch not blocked"
    PASS=$((PASS + 1))
else
    echo "[FAIL] expected exit 0, got $rc"
    FAIL=$((FAIL + 1))
fi

# ── Test 5: update push (existing branch, not zeros) → allowed ───────────────
echo ""
echo "Test 5: force-push to existing chump branch (remote_sha != zeros) → exit 0"
rc=$(run_hook "" "$NONZERO_SHA" "chump/infra-999-claim")
if [[ "$rc" -eq 0 ]]; then
    echo "[PASS] update push (existing PR) allowed"
    PASS=$((PASS + 1))
else
    echo "[FAIL] expected exit 0, got $rc"
    FAIL=$((FAIL + 1))
fi

# ── Test 6: chump branch with no gap-id pattern → not blocked ────────────────
echo ""
echo "Test 6: chump/fix-auth-issue (no <domain>-<number> pattern) → exit 0"
rc=$(run_hook "" "$ZERO_SHA" "chump/fix-auth-issue")
# "fix-auth-issue" has no numeric component after domain prefix, so no gap match.
if [[ "$rc" -eq 0 ]]; then
    echo "[PASS] non-gap-pattern chump branch not blocked"
    PASS=$((PASS + 1))
else
    echo "[FAIL] expected exit 0 for non-gap-pattern branch, got $rc"
    FAIL=$((FAIL + 1))
fi

# ── Test 7: product gap branch → also guarded ────────────────────────────────
echo ""
echo "Test 7: chump/product-050-claim (product domain) → exit 1"
rc=$(run_hook "" "$ZERO_SHA" "chump/product-050-claim")
if [[ "$rc" -eq 1 ]]; then
    echo "[PASS] PRODUCT gap branch also blocked"
    PASS=$((PASS + 1))
else
    echo "[FAIL] expected exit 1 for PRODUCT gap branch, got $rc"
    FAIL=$((FAIL + 1))
fi

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "Results: $PASS passed, $FAIL failed"
if [[ $FAIL -gt 0 ]]; then
    exit 1
fi
echo "[OK] all INFRA-719 no-manual-ship-bypass tests passed"
