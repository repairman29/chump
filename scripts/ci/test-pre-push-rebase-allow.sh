#!/usr/bin/env bash
# test-pre-push-rebase-allow.sh — INFRA-368 regression test.
#
# Verifies the pre-push hook auto-skips Guards 1+2 when a recent
# `git rebase` reflog entry is detected, but still fires for manual
# amend / unrelated force-push scenarios.
#
# 4 cases:
#   1. recent rebase + push to armed branch → auto-skip Guard 2 (allowed)
#   2. CHUMP_REBASE_DETECT=0 + same scenario → Guard 2 fires (blocked)
#   3. amend + push (no rebase reflog entry) → Guard 2 fires (blocked)
#   4. recent rebase + Guard 3 race scenario → Guard 3 still fires (blocked)
#
# Stand up a local bare "remote" + clone, simulate each scenario by
# manipulating the clone's reflog and invoking the hook with the
# appropriate stdin format.

set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
HOOK="$REPO_ROOT/scripts/git-hooks/pre-push"

[[ -x "$HOOK" ]] || { echo "[FAIL] pre-push hook not found / not executable"; exit 1; }

TMP="$(cd "$(mktemp -d)" && pwd -P)"
trap 'rm -rf "$TMP"' EXIT

# ── Setup: bare origin + clone with a feature branch ─────────────────────
mkdir -p "$TMP/origin.git" && cd "$TMP/origin.git" && git init --bare -q
cd "$TMP" && git clone -q origin.git clone1
cd clone1 && git config user.email t@t && git config user.name t
echo "v0" > a.txt && git add a.txt && git commit -qm "v0"
git push -q origin HEAD
git checkout -qb feature
echo "alpha" > b.txt && git add b.txt && git commit -qm "alpha"
git push -qu origin feature
LOCAL_SHA=$(git rev-parse HEAD)
REMOTE_SHA=$(git rev-parse origin/feature)

# Stub gh: mark feature as auto-merge-armed so Guard 2 would fire.
mkdir -p "$TMP/bin"
cat > "$TMP/bin/gh" <<'STUB'
#!/usr/bin/env bash
if [[ "$1 $2" == "pr view" ]] && [[ " $* " == *" --json "* ]]; then
    if [[ " $* " == *"--jq"* ]]; then
        echo "true"
    else
        echo '{"state":"OPEN","autoMergeRequest":{"enabledAt":"2026-05-03T00:00:00Z"}}'
    fi
    exit 0
fi
exit 0
STUB
chmod +x "$TMP/bin/gh"

run_hook() {
    local input="refs/heads/feature $LOCAL_SHA refs/heads/feature $REMOTE_SHA"
    PATH="$TMP/bin:/usr/bin:/bin" CHUMP_GAP_CHECK=0 \
        bash -c "cd '$TMP/clone1' && echo '$input' | bash '$HOOK' '$TMP/origin.git' '$TMP/origin.git' 2>&1"
}

# ── Test 1: simulate recent rebase via reflog entry → Guards 1+2 skip ────
echo "Test 1: recent 'rebase' reflog entry → Guard 2 auto-skips"
# Forge a reflog entry. git rebase writes "rebase (start)" / "rebase (finish)".
# `git update-ref --create-reflog HEAD <sha> -m "rebase (finish): ..."` works.
git -C "$TMP/clone1" update-ref -m "rebase (finish): returning to refs/heads/feature" HEAD HEAD
set +e
out=$(run_hook)
rc=$?
set -e
if [[ $rc -ne 0 ]]; then
    echo "[FAIL] expected exit 0 (auto-skip) got $rc"
    echo "$out"
    exit 1
fi
if ! echo "$out" | grep -q "INFRA-368: recent rebase detected"; then
    echo "[FAIL] missing rebase-detected diagnostic"
    echo "$out"
    exit 1
fi
echo "[PASS]"

# ── Test 2: CHUMP_REBASE_DETECT=0 → Guard 2 blocks ───────────────────────
echo ""
echo "Test 2: CHUMP_REBASE_DETECT=0 disables auto-skip"
set +e
out=$(PATH="$TMP/bin:/usr/bin:/bin" CHUMP_GAP_CHECK=0 CHUMP_REBASE_DETECT=0 \
    bash -c "cd '$TMP/clone1' && echo 'refs/heads/feature $LOCAL_SHA refs/heads/feature $REMOTE_SHA' | bash '$HOOK' '$TMP/origin.git' '$TMP/origin.git' 2>&1")
rc=$?
set -e
if [[ $rc -eq 0 ]]; then
    echo "[FAIL] expected block (Guard 2) got exit 0"
    echo "$out"
    exit 1
fi
if ! echo "$out" | grep -q "auto-merge armed"; then
    echo "[FAIL] expected 'auto-merge armed' diagnostic, got:"
    echo "$out"
    exit 1
fi
echo "[PASS]"

# ── Test 3: no recent rebase reflog → Guard 2 still fires ────────────────
echo ""
echo "Test 3: no rebase entry → Guard 2 fires normally"
# Re-clone fresh so the reflog is clean (no rebase entry).
cd "$TMP" && rm -rf clone2 && git clone -q origin.git clone2
cd clone2 && git config user.email t@t && git config user.name t
git checkout -qb feature origin/feature
LOCAL_SHA2=$(git rev-parse HEAD)
REMOTE_SHA2=$(git rev-parse origin/feature)
set +e
out=$(PATH="$TMP/bin:/usr/bin:/bin" CHUMP_GAP_CHECK=0 \
    bash -c "cd '$TMP/clone2' && echo 'refs/heads/feature $LOCAL_SHA2 refs/heads/feature $REMOTE_SHA2' | bash '$HOOK' '$TMP/origin.git' '$TMP/origin.git' 2>&1")
rc=$?
set -e
if [[ $rc -eq 0 ]]; then
    echo "[FAIL] expected block (Guard 2) got exit 0; reflog check leaked through"
    echo "$out"
    exit 1
fi
if ! echo "$out" | grep -q "auto-merge armed"; then
    echo "[FAIL] expected 'auto-merge armed' diagnostic"
    echo "$out"
    exit 1
fi
echo "[PASS]"

# ── Test 4: rebase detected but Guard 3 race scenario → Guard 3 still fires ─
echo ""
echo "Test 4: rebase detected + Guard 3 race → Guard 3 still blocks"
# Sibling pushes to origin/feature so the local view is stale.
cd "$TMP" && git clone -q origin.git sibling
cd sibling && git config user.email s@s && git config user.name s
git checkout -qb feature origin/feature
echo "sibling_change" > c.txt && git add c.txt && git commit -qm "sibling commit"
git push -q origin feature
NEW_REMOTE_SHA=$(git rev-parse HEAD)

# Back in clone1: rewrite history (force-push) without re-fetching.
cd "$TMP/clone1"
echo "main_change" > d.txt && git add d.txt && git commit --amend -qm "alpha v2"
git update-ref -m "rebase (finish): test force" HEAD HEAD  # forge rebase reflog
LOCAL_SHA3=$(git rev-parse HEAD)
# Stale local view of remote (NOT $NEW_REMOTE_SHA — clone1 hasn't fetched)
STALE_VIEW_SHA=$(git rev-parse origin/feature)

set +e
out=$(PATH="$TMP/bin:/usr/bin:/bin" CHUMP_AUTOMERGE_OVERRIDE=1 CHUMP_GAP_CHECK=0 \
    bash -c "cd '$TMP/clone1' && echo 'refs/heads/feature $LOCAL_SHA3 refs/heads/feature $STALE_VIEW_SHA' | bash '$HOOK' '$TMP/origin.git' '$TMP/origin.git' 2>&1")
rc=$?
set -e
if [[ $rc -eq 0 ]]; then
    echo "[FAIL] Guard 3 should have fired (sibling commit would be clobbered) but exit=0"
    echo "$out"
    exit 1
fi
if ! echo "$out" | grep -q "force-push race detected"; then
    echo "[FAIL] expected Guard 3 'force-push race detected' diagnostic"
    echo "$out"
    exit 1
fi
echo "[PASS] (Guard 3 still fires even when rebase detected — race protection regardless)"

echo ""
echo "[OK] all 4 INFRA-368 rebase-allow cases passed"
