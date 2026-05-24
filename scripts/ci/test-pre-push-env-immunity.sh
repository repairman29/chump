#!/usr/bin/env bash
# test-pre-push-env-immunity.sh — INFRA-1950 regression test.
#
# Verifies the pre-push hook is immune to GIT_DIR / GIT_WORK_TREE /
# GITHUB_WORKSPACE env-leakage from the GitHub Actions self-hosted
# runner-listener. Without the INFRA-1950 hardening, those leaked vars
# silently redirected `git merge-base --is-ancestor` and other Guard 3
# checks at a foreign repo, so the race-check never fired and main went
# red 5/5 runs in a row between 16:05Z and 18:22Z on 2026-05-23.
#
# Strategy: stand up a local "remote" + clone (same setup as the
# INFRA-345 force-lease test), then inject fake GIT_DIR / GIT_WORK_TREE /
# GITHUB_WORKSPACE pointing at scratch directories that DO NOT contain
# the test's commits. Assert the hook still resolves the real repo and
# exits cleanly (no "not a git command" errors, no silent pass when
# Guard 3 should block).

set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
HOOK="$REPO_ROOT/scripts/git-hooks/pre-push"

if [[ ! -x "$HOOK" ]]; then
    echo "[FAIL] pre-push hook not found / not executable at $HOOK"
    exit 1
fi

TMP="$(cd "$(mktemp -d)" && pwd -P)"
# Fake env-leak targets — these dirs are NOT git repos. If the hook
# inherits them, every `git` call will either fail outright or resolve
# to the wrong tree.
FAKE_GIT_DIR="$TMP/fake-git-dir"
FAKE_WORK_TREE="$TMP/fake-work-tree"
FAKE_WORKSPACE="$TMP/fake-workspace"
mkdir -p "$FAKE_GIT_DIR" "$FAKE_WORK_TREE" "$FAKE_WORKSPACE"

trap 'rm -rf "$TMP"' EXIT

# Stand up a real bare remote + clone with a divergent feature branch so
# Guard 3 (force-with-lease race) is actually exercised.
mkdir -p "$TMP/origin.git" && cd "$TMP/origin.git" && git init --bare -q
cd "$TMP" && git clone -q origin.git workrepo
cd workrepo
git config user.email t@t && git config user.name t
echo "v0" > a.txt && git add a.txt && git commit -qm "v0"
git push -q origin main 2>/dev/null || git push -q origin master
DEFAULT_BRANCH=$(git symbolic-ref --short HEAD)
git checkout -qb feature
echo "alpha" > b.txt && git add b.txt && git commit -qm "alpha"
git push -qu origin feature

# Sibling clone pushes ahead so our local view of origin/feature is stale.
cd "$TMP" && git clone -q origin.git sibling
cd sibling && git config user.email s@s && git config user.name s
git checkout -qb feature origin/feature
echo "sib" > c.txt && git add c.txt && git commit -qm "sibling-commit"
git push -q origin feature

# Back in main clone — rewrite history so a force-push would happen.
cd "$TMP/workrepo"
git checkout -q feature
echo "us" > d.txt && git add d.txt && git commit --amend -qm "alpha v2"
LOCAL_SHA=$(git rev-parse HEAD)
LOCAL_VIEW_REMOTE_SHA=$(git rev-parse origin/feature)  # stale

# Compose the standard pre-push stdin line.
INPUT="refs/heads/feature $LOCAL_SHA refs/heads/feature $LOCAL_VIEW_REMOTE_SHA"

# ──────────────────────────────────────────────────────────────────────
# Test 1: with GIT_DIR/GIT_WORK_TREE/GITHUB_WORKSPACE pointing at fake
# scratch dirs, the hook must still resolve the real repo and BLOCK the
# stale-fetch force-push exactly as it would without the env-leak.
# ──────────────────────────────────────────────────────────────────────
echo "Test 1: env-leak injection must NOT defeat Guard 3"
set +e
out=$(
    echo "$INPUT" | \
    GIT_DIR="$FAKE_GIT_DIR" \
    GIT_WORK_TREE="$FAKE_WORK_TREE" \
    GITHUB_WORKSPACE="$FAKE_WORKSPACE" \
    CHUMP_AUTOMERGE_OVERRIDE=1 \
    CHUMP_GAP_CHECK=0 \
    CHUMP_FMT_CHECK=0 \
    CHUMP_TEST_GATE=0 \
    CHUMP_CLIPPY_GATE=0 \
    CHUMP_MERGE_PREVIEW=0 \
    CHUMP_FIXTURE_AUTHOR_GUARD=0 \
    CHUMP_CI_REGRESSION_GUARD=0 \
    CHUMP_PREFLIGHT_SKIP=1 \
    CHUMP_BYPASS_BOT_MERGE=1 \
    "$HOOK" "$TMP/origin.git" "$TMP/origin.git" 2>&1
)
rc=$?
set -e

# Assertion A: no "not a git command" / "fatal: not a git repository" errors.
if echo "$out" | grep -qE '(is not a git command|not a git repository)'; then
    echo "[FAIL] hook leaked the foreign env into a git call:"
    echo "$out"
    exit 1
fi

# Assertion B: Guard 3 fired (rc=1 + race-detection diagnostic). If the
# env-leak HAD defeated us, the merge-base call would have resolved
# against the fake (empty) GIT_DIR and either errored or returned a bogus
# ancestry result, causing the guard to either crash or silently pass.
if [[ $rc -eq 0 ]]; then
    echo "[FAIL] hook exited 0 — env-leak likely defeated Guard 3 (the bug)"
    echo "$out"
    exit 1
fi

if ! echo "$out" | grep -q "force-push race detected"; then
    echo "[FAIL] hook exited $rc but didn't print the Guard 3 race diagnostic"
    echo "$out"
    exit 1
fi

echo "[PASS] Guard 3 fired correctly despite GIT_DIR / GIT_WORK_TREE / GITHUB_WORKSPACE injection"

# ──────────────────────────────────────────────────────────────────────
# Test 2: without env-leak the same scenario must also block — proves
# the new defence didn't accidentally weaken the existing protection.
# ──────────────────────────────────────────────────────────────────────
echo ""
echo "Test 2: same scenario without env-leak still blocks (regression)"
set +e
out=$(
    echo "$INPUT" | \
    CHUMP_AUTOMERGE_OVERRIDE=1 \
    CHUMP_GAP_CHECK=0 \
    CHUMP_FMT_CHECK=0 \
    CHUMP_TEST_GATE=0 \
    CHUMP_CLIPPY_GATE=0 \
    CHUMP_MERGE_PREVIEW=0 \
    CHUMP_FIXTURE_AUTHOR_GUARD=0 \
    CHUMP_CI_REGRESSION_GUARD=0 \
    CHUMP_PREFLIGHT_SKIP=1 \
    CHUMP_BYPASS_BOT_MERGE=1 \
    "$HOOK" "$TMP/origin.git" "$TMP/origin.git" 2>&1
)
rc=$?
set -e

if [[ $rc -eq 0 ]] || ! echo "$out" | grep -q "force-push race detected"; then
    echo "[FAIL] clean-env scenario didn't block (rc=$rc) — regression in Guard 3"
    echo "$out"
    exit 1
fi
echo "[PASS] clean-env behaviour unchanged (Guard 3 still blocks)"

# ──────────────────────────────────────────────────────────────────────
# Test 3: hook unsets the leak vars from its OWN process env (defence
# in depth — children spawned by the hook see a clean env). We can
# observe this by sourcing the hook in a dry-run mode and checking the
# vars are gone. Since we can't easily "dry-run" the hook, we instead
# parse the source and assert the unset directive is present at the
# top of the file (the defensive measure required by AC #2).
# ──────────────────────────────────────────────────────────────────────
echo ""
echo "Test 3: hook script contains the defensive unset directive"
if ! head -120 "$HOOK" | grep -qE '^unset GIT_DIR GIT_WORK_TREE GITHUB_WORKSPACE'; then
    echo "[FAIL] pre-push hook missing the defensive 'unset' for env-leak vars"
    echo "       Expected: 'unset GIT_DIR GIT_WORK_TREE GITHUB_WORKSPACE ...' near top"
    exit 1
fi
echo "[PASS] defensive unset directive present (INFRA-1950)"

# ──────────────────────────────────────────────────────────────────────
# Test 4: hook script computes REPO_ROOT from BASH_SOURCE (env-immune).
# Assert the canonical pattern is present so future edits cannot silently
# drop the immunity.
# ──────────────────────────────────────────────────────────────────────
echo ""
echo "Test 4: hook computes REPO_ROOT from BASH_SOURCE (env-immune)"
# The hook derives REPO_ROOT by first cd'ing to $(dirname "${BASH_SOURCE[0]}")
# then resolving ../.. via a second cd. Look for both ingredients on
# adjacent lines rather than a single regex (BASH_SOURCE appears on the
# _pp_script_dir line, REPO_ROOT assignment is two lines below).
if ! grep -qE 'BASH_SOURCE\[0\]' "$HOOK"; then
    echo "[FAIL] pre-push hook missing BASH_SOURCE-based derivation"
    echo "       Expected: _pp_script_dir=\"\$(cd \"\$(dirname \"\${BASH_SOURCE[0]}\")\" ...)\""
    exit 1
fi
if ! grep -qE 'REPO_ROOT="\$\(cd "\$_pp_script_dir' "$HOOK"; then
    echo "[FAIL] pre-push hook missing REPO_ROOT computation from _pp_script_dir"
    echo "       Expected: REPO_ROOT=\"\$(cd \"\$_pp_script_dir/../..\" ...)\""
    exit 1
fi
echo "[PASS] BASH_SOURCE-based REPO_ROOT pattern present (INFRA-1950)"

# ──────────────────────────────────────────────────────────────────────
# Test 5: at least one inner git call uses the `git -C "$REPO_ROOT"`
# pattern. The race-check (Guard 3 merge-base + ls-remote) is the
# critical site — verify it specifically.
# ──────────────────────────────────────────────────────────────────────
echo ""
echo "Test 5: Guard 3 git calls use 'git -C \"\$REPO_ROOT\"' (env-immune)"
if ! grep -qE 'git -C "\$REPO_ROOT" merge-base --is-ancestor' "$HOOK"; then
    echo "[FAIL] Guard 3 merge-base call is not env-immune (missing -C \"\$REPO_ROOT\")"
    exit 1
fi
if ! grep -qE 'git -C "\$REPO_ROOT" ls-remote' "$HOOK"; then
    echo "[FAIL] Guard 3 ls-remote call is not env-immune (missing -C \"\$REPO_ROOT\")"
    exit 1
fi
echo "[PASS] Guard 3 force-with-lease race-check is env-immune"

echo ""
echo "[OK] all 5 INFRA-1950 env-immunity cases passed"
