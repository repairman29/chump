#!/usr/bin/env bash
# test-force-stale-base-guard.sh — INFRA-2005 regression test.
#
# Verifies the pre-push hook's Guard 6a (stale-base ancestry check) blocks
# force-pushes when HEAD does not contain origin/main as an ancestor, but
# allows them after rebasing or when explicitly bypassed.
#
# Catalyst: 2026-05-25 incident — Opus pushed stale chump/opus-shepherd-*
# HEAD (based on old main) over chump/infra-1974-claim, auto-closing PR #2582.
#
# Strategy: stand up a local "remote" (bare repo) + clone, create a synthetic
# scenario where the local branch is 50+ commits behind origin/main, then
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
unset CHUMP_REPO CHUMP_LOCK_DIR

# 1. Set up bare "origin" + clone.
mkdir -p "$TMP/origin.git" && cd "$TMP/origin.git" && git init --bare -q
cd "$TMP" && git clone -q origin.git clone
cd clone
git config user.email t@t && git config user.name t
echo "v0" > a.txt && git add a.txt && git commit -qm "v0"
git push -q origin main 2>/dev/null || git push -q origin master
DEFAULT_BRANCH=$(git symbolic-ref --short HEAD)

# 2. Create the branch structure: claim-style branch based on old main.
git checkout -qb "chump/test-999-claim"
echo "initial work" > work.txt && git add work.txt && git commit -qm "initial work"
git push -qu origin "chump/test-999-claim"

# Store the current HEAD (based on old main)
STALE_HEAD=$(git rev-parse HEAD)
STALE_REMOTE_SHA=$(git rev-parse origin/chump/test-999-claim)

# 3. Advance origin/main by 50+ commits (simulating time passing on main while
#    our branch stays based on the old HEAD).
git checkout -q "$DEFAULT_BRANCH"
for i in {1..50}; do
    echo "main change $i" > "main_$i.txt"
    git add "main_$i.txt"
    git commit -qm "main commit $i"
done
git push -q origin "$DEFAULT_BRANCH"

# 4. Back on our claim branch, rewrite the commit (force-push scenario).
#    We amend the current commit to create a history divergence (force-push).
git checkout -q "chump/test-999-claim"
echo "amended work" > work.txt
git add work.txt
git commit --amend -qm "amended initial work"
NEW_HEAD=$(git rev-parse HEAD)

# Verify: this is a force-push (amended commit is NOT ancestor of remote)
if git merge-base --is-ancestor "$STALE_REMOTE_SHA" "$NEW_HEAD" 2>/dev/null; then
    echo "[setup-FAIL] expected force-push scenario (amended commit should diverge from remote)"
    exit 1
fi

# Verify: the new HEAD is NOT an ancestor of origin/main (our base is stale).
if git merge-base --is-ancestor "$NEW_HEAD" origin/main 2>/dev/null; then
    echo "[setup-FAIL] expected stale base scenario; local is still ancestor of main"
    exit 1
fi

# 5. Test 1: Force-push attempt must be BLOCKED by Guard 6a.
echo "Test 1: stale-base force-push must be blocked"
input="refs/heads/chump/test-999-claim $NEW_HEAD refs/heads/chump/test-999-claim $STALE_REMOTE_SHA"
set +e
out=$(echo "$input" | CHUMP_AUTOMERGE_OVERRIDE=1 CHUMP_GAP_CHECK=0 \
    CHUMP_FMT_CHECK=0 CHUMP_TEST_GATE=0 \
    CHUMP_FORCE_LEASE_CHECK=0 \
    CHUMP_STALE_REBASE_MAX_BEHIND=999 \
    "$HOOK" "$TMP/origin.git" "$TMP/origin.git" 2>&1)
rc=$?
set -e
if [[ $rc -eq 0 ]]; then
    echo "[FAIL] hook allowed the stale-base force-push (expected exit 1)"
    echo "$out"
    exit 1
fi
if ! echo "$out" | grep -q "stale base"; then
    echo "[FAIL] hook exited $rc but didn't print the stale base diagnostic"
    echo "$out"
    exit 1
fi
echo "[PASS] Guard 6a blocked stale-base force-push (rc=$rc, diagnostic printed)"

# 6. Test 2: After rebasing on origin/main, the push should be allowed.
echo ""
echo "Test 2: after rebasing on origin/main, force-push must be allowed"
git fetch -q origin "$DEFAULT_BRANCH"
git rebase -q "origin/$DEFAULT_BRANCH" || { git rebase --abort 2>/dev/null; true; }
REBASED_HEAD=$(git rev-parse HEAD)

# Now verify that the rebased HEAD contains origin/main as ancestor.
if ! git merge-base --is-ancestor origin/main "$REBASED_HEAD" 2>/dev/null; then
    echo "[setup-FAIL] rebase should have made HEAD include origin/main as ancestor"
    exit 1
fi

input2="refs/heads/chump/test-999-claim $REBASED_HEAD refs/heads/chump/test-999-claim $STALE_REMOTE_SHA"
set +e
out=$(echo "$input2" | CHUMP_AUTOMERGE_OVERRIDE=1 CHUMP_GAP_CHECK=0 \
    CHUMP_FMT_CHECK=0 CHUMP_TEST_GATE=0 \
    CHUMP_FORCE_LEASE_CHECK=0 \
    "$HOOK" "$TMP/origin.git" "$TMP/origin.git" 2>&1)
rc=$?
set -e
if [[ $rc -ne 0 ]]; then
    echo "[FAIL] hook rejected rebased force-push (rc=$rc)"
    echo "$out"
    exit 1
fi
echo "[PASS] rebased force-push allowed (rc=$rc)"

# 7. Test 3: Bypass CHUMP_FORCE_STALE_BASE=1 (with trailer) must allow stale push.
echo ""
echo "Test 3: CHUMP_FORCE_STALE_BASE=1 must bypass the stale-base check"
# Reset to stale HEAD for this test
git checkout -q "$STALE_HEAD"
git commit --allow-empty -qm "empty commit with bypass trailer

Force-Stale-Base-Bypass: operator override for testing purposes"
BYPASSED_HEAD=$(git rev-parse HEAD)
input3="refs/heads/chump/test-999-claim $BYPASSED_HEAD refs/heads/chump/test-999-claim $STALE_REMOTE_SHA"
set +e
out=$(echo "$input3" | CHUMP_AUTOMERGE_OVERRIDE=1 CHUMP_GAP_CHECK=0 \
    CHUMP_FMT_CHECK=0 CHUMP_TEST_GATE=0 \
    CHUMP_FORCE_LEASE_CHECK=0 \
    CHUMP_STALE_REBASE_MAX_BEHIND=999 \
    CHUMP_FORCE_STALE_BASE=1 \
    "$HOOK" "$TMP/origin.git" "$TMP/origin.git" 2>&1)
rc=$?
set -e
if [[ $rc -ne 0 ]]; then
    echo "[FAIL] bypass env didn't allow the stale-base push (rc=$rc)"
    echo "$out"
    exit 1
fi
if ! echo "$out" | grep -q "INFRA-2005: stale-base check bypassed"; then
    echo "[WARN] hook allowed the push but didn't print bypass audit message"
fi
echo "[PASS] CHUMP_FORCE_STALE_BASE=1 bypass works"

# 8. Test 4: Non-claim branch should not trigger Guard 6a.
echo ""
echo "Test 4: non-claim branches should skip Guard 6a"
git checkout -qb "chump/feature-branch"
echo "feature work" > feature.txt && git add feature.txt && git commit -qm "feature"
git push -qu origin "chump/feature-branch"
FEATURE_HEAD=$(git rev-parse HEAD)
FEATURE_REMOTE=$(git rev-parse origin/chump/feature-branch)
input4="refs/heads/chump/feature-branch $FEATURE_HEAD refs/heads/chump/feature-branch $FEATURE_REMOTE"
set +e
out=$(echo "$input4" | CHUMP_AUTOMERGE_OVERRIDE=1 CHUMP_GAP_CHECK=0 \
    CHUMP_FMT_CHECK=0 CHUMP_TEST_GATE=0 \
    CHUMP_FORCE_LEASE_CHECK=0 \
    "$HOOK" "$TMP/origin.git" "$TMP/origin.git" 2>&1)
rc=$?
set -e
# Should not be blocked by Guard 6a (fast-forward, not a force-push)
if [[ $rc -ne 0 ]]; then
    echo "[FAIL] hook rejected non-claim branch (rc=$rc)"
    echo "$out"
    exit 1
fi
echo "[PASS] non-claim branches skip Guard 6a correctly"

echo ""
echo "[OK] all 4 INFRA-2005 stale-base guard cases passed"
