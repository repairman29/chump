#!/usr/bin/env bash
# test-pre-push-force-lease-guard.sh — INFRA-345 regression test.
#
# Verifies the pre-push hook's Guard 3 (--force-with-lease race
# protection) blocks force-pushes when the remote has moved since the
# local fetch, but allows them when the local view is fresh.
#
# Strategy: stand up a local "remote" (bare repo) + two clones, simulate
# the race (sibling push between fetch and push from main clone), then
# invoke the hook directly with the appropriate stdin format and assert
# exit code + diagnostic message.

set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
HOOK="$REPO_ROOT/scripts/git-hooks/pre-push"

if [[ ! -x "$HOOK" ]]; then
    echo "[FAIL] pre-push hook not found / not executable at $HOOK"
    exit 1
fi

TMP="$(cd "$(mktemp -d)" && pwd -P)"
trap 'rm -rf "$TMP"' EXIT

# W-013 immunization (RESILIENT-024 followup): unset workflow-injected env
# so the pre-push hook executed under this test reads $REPO_ROOT-relative
# paths instead of a workflow-injected /home/runner/.../.chump-locks that
# points at an unrelated repo. The hook writes ambient events and reads
# session state from $REPO_ROOT/.chump-locks; CHUMP_LOCK_DIR override
# poisons that lookup.
unset CHUMP_REPO CHUMP_LOCK_DIR

# 1. Set up bare "origin" + two clones.
mkdir -p "$TMP/origin.git" && cd "$TMP/origin.git" && git init --bare -q
cd "$TMP" && git clone -q origin.git main_clone
cd main_clone
git config user.email t@t && git config user.name t
echo "v0" > a.txt && git add a.txt && git commit -qm "v0"
git push -q origin main 2>/dev/null || git push -q origin master
DEFAULT_BRANCH=$(git symbolic-ref --short HEAD)
git checkout -qb feature
echo "alpha" > b.txt && git add b.txt && git commit -qm "alpha"
git push -qu origin feature

cd "$TMP" && git clone -q origin.git sibling_clone
cd sibling_clone && git config user.email s@s && git config user.name s
git checkout -qb feature origin/feature

# 2. Sibling pushes a commit BEFORE main_clone has a chance to fetch.
echo "sibling_change" > c.txt && git add c.txt && git commit -qm "sibling commit"
git push -q origin feature

# 3. Main clone tries to force-push without re-fetching. Its local view of
#    origin/feature is the OLD sha. Simulate `--force-with-lease` succeeding
#    locally by crafting a divergent history then asking the hook to vet it.
cd "$TMP/main_clone"
git checkout -q feature
echo "main_change" > d.txt && git add d.txt && git commit --amend -qm "alpha v2"  # rewrite history
LOCAL_SHA=$(git rev-parse HEAD)
LOCAL_VIEW_REMOTE_SHA=$(git rev-parse origin/feature)  # stale (pre-sibling push)

# Sanity: this is in fact a force-push (local NOT a descendant of stale view? actually yes — amend rewrote)
if git merge-base --is-ancestor "$LOCAL_VIEW_REMOTE_SHA" "$LOCAL_SHA"; then
    echo "[setup-FAIL] expected a force-push scenario; got a fast-forward"
    exit 1
fi

# 4. Test 1: Guard 3 must BLOCK because actual remote ≠ local's view.
echo "Test 1: stale-fetch force-push must be blocked"
input="refs/heads/feature $LOCAL_SHA refs/heads/feature $LOCAL_VIEW_REMOTE_SHA"
set +e
out=$(echo "$input" | CHUMP_AUTOMERGE_OVERRIDE=1 CHUMP_GAP_CHECK=0 \
    CHUMP_FMT_CHECK=0 CHUMP_TEST_GATE=0 \
    "$HOOK" "$TMP/origin.git" "$TMP/origin.git" 2>&1)
rc=$?
set -e
if [[ $rc -eq 0 ]]; then
    echo "[FAIL] hook allowed the stale-fetch force-push (expected exit 1)"
    echo "$out"
    exit 1
fi
if ! echo "$out" | grep -q "force-push race detected"; then
    echo "[FAIL] hook exited $rc but didn't print the expected diagnostic"
    echo "$out"
    exit 1
fi
echo "[PASS] Guard 3 blocked stale-fetch force-push (rc=$rc, diagnostic printed)"

# 5. Test 2: Bypass env CHUMP_FORCE_LEASE_CHECK=0 must allow.
echo ""
echo "Test 2: CHUMP_FORCE_LEASE_CHECK=0 must allow the same scenario"
set +e
out=$(echo "$input" | CHUMP_AUTOMERGE_OVERRIDE=1 CHUMP_GAP_CHECK=0 \
    CHUMP_FMT_CHECK=0 CHUMP_TEST_GATE=0 \
    CHUMP_FORCE_LEASE_CHECK=0 "$HOOK" "$TMP/origin.git" "$TMP/origin.git" 2>&1)
rc=$?
set -e
if [[ $rc -ne 0 ]]; then
    echo "[FAIL] bypass env didn't allow the push (rc=$rc)"
    echo "$out"
    exit 1
fi
echo "[PASS] CHUMP_FORCE_LEASE_CHECK=0 bypass works"

# 6. Test 3: Fresh fetch + retry must allow (remote tip == local view).
echo ""
echo "Test 3: fresh-fetch force-push must be allowed"
git fetch -q origin feature
FRESH_REMOTE_SHA=$(git rev-parse origin/feature)
# Rebase local on fresh remote so the force-push is a real history rewrite
# but with a fresh "expected" sha.
git rebase -q origin/feature || { git rebase --abort 2>/dev/null; }
# After rebase the new HEAD is what we'd push.
NEW_LOCAL_SHA=$(git rev-parse HEAD)
input2="refs/heads/feature $NEW_LOCAL_SHA refs/heads/feature $FRESH_REMOTE_SHA"
set +e
out=$(echo "$input2" | CHUMP_AUTOMERGE_OVERRIDE=1 CHUMP_GAP_CHECK=0 \
    CHUMP_FMT_CHECK=0 CHUMP_TEST_GATE=0 \
    "$HOOK" "$TMP/origin.git" "$TMP/origin.git" 2>&1)
rc=$?
set -e
# Note: if the rebase made it a fast-forward, Guard 3 wouldn't trigger
# (correctly) and the push would be allowed. If history is still divergent
# (rebase produced different SHAs), Guard 3 should pass because the
# expected-sha matches the actual remote sha.
if [[ $rc -ne 0 ]]; then
    echo "[FAIL] hook rejected fresh-fetch force-push (rc=$rc)"
    echo "$out"
    exit 1
fi
echo "[PASS] fresh-fetch force-push allowed (rc=$rc)"

# 7. Test 4: New-branch push (remote_sha = all zeros) must be allowed
#    regardless of fetch state — Guard 3 explicitly skips this case.
echo ""
echo "Test 4: new-branch push (remote_sha = zeros) must skip Guard 3"
ZEROS="0000000000000000000000000000000000000000"
input3="refs/heads/new-branch $NEW_LOCAL_SHA refs/heads/new-branch $ZEROS"
set +e
out=$(echo "$input3" | CHUMP_AUTOMERGE_OVERRIDE=1 CHUMP_GAP_CHECK=0 \
    CHUMP_FMT_CHECK=0 CHUMP_TEST_GATE=0 \
    "$HOOK" "$TMP/origin.git" "$TMP/origin.git" 2>&1)
rc=$?
set -e
if [[ $rc -ne 0 ]]; then
    echo "[FAIL] hook rejected new-branch push (rc=$rc)"
    echo "$out"
    exit 1
fi
echo "[PASS] new-branch push allowed (Guard 3 correctly skipped)"

echo ""
echo "[OK] all 4 INFRA-345 force-with-lease guard cases passed"
