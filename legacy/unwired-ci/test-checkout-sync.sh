#!/usr/bin/env bash
# scripts/ci/test-checkout-sync.sh — MISSION-027
#
# Verifies scripts/ops/checkout-sync.sh: the checkout-sync daemon that keeps
# the RUNNING checkout (scripts/dispatch/_pick_gap.py and friends) current
# with origin/main, independent of MISSION-012's binary-only auto-deploy.
#
# Acceptance criteria verified (MISSION-027):
#   (1) A merged script fix on origin/main reaches a stale local checkout via
#       one checkout-sync.sh run (AC 1 + AC 2 + AC 4).
#   (2) The dirty-tree case does not block the sync: disposable runtime state
#       (e.g. .chump/github_cache.db) is silently reset, legit local edits
#       are stashed (not discarded) and restored after the fast-forward
#       (AC 3).
#   (3) Already-current checkout is a clean no-op (idempotent).
#   (4) A non-main branch is never touched.
#   (5) checkout_synced / checkout_sync_dirty_tree_protected are
#       scanner-anchored AND registered in EVENT_REGISTRY.yaml.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SYNC="$REPO_ROOT/scripts/ops/checkout-sync.sh"
REG="$REPO_ROOT/docs/observability/EVENT_REGISTRY.yaml"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

ok()   { printf '\033[0;32mPASS\033[0m %s\n' "$*"; }
fail() { printf '\033[0;31mFAIL\033[0m %s\n' "$*"; exit 1; }

# ── Static checks ───────────────────────────────────────────────────────────
[[ -x "$SYNC" ]] || fail "checkout-sync.sh missing or not executable"
grep -q 'MISSION-027' "$SYNC" || fail "MISSION-027 banner missing"
grep -q 'merge --ff-only origin/main' "$SYNC" || fail "ff-only merge missing"
grep -q 'git stash push' "$SYNC" || fail "dirty-tree stash protection missing"

for kind in checkout_synced checkout_sync_failed checkout_sync_dirty_tree_protected checkout_sync_skipped; do
    grep -q "scanner-anchor: \"kind\":\"$kind\"" "$SYNC" \
        || fail "$kind missing its scanner-anchor comment"
    grep -q "kind: $kind" "$REG" \
        || fail "EVENT_REGISTRY.yaml missing kind: $kind"
done
ok "checkout-sync events are scanner-anchored and registered"

# ── Fixtures ─────────────────────────────────────────────────────────────────
# A real local "origin" repo (bare) + a real local "checkout" clone, so
# `git fetch` + `git merge --ff-only` exercise real git plumbing rather than
# stubs.
ORIGIN="$TMP/origin.git"
git init -q --bare "$ORIGIN"

CHECKOUT="$TMP/checkout"
git clone -q "$ORIGIN" "$CHECKOUT"
(
    cd "$CHECKOUT" || exit 1
    git config user.email "test@example.com"
    git config user.name "Test"
    git checkout -q -b main 2>/dev/null || git checkout -q main
    echo "v1" > pick_gap.py
    git add pick_gap.py
    git commit -q -m init
    git push -q -u origin main
)
git --git-dir="$ORIGIN" symbolic-ref HEAD refs/heads/main

run_sync() {
    CHUMP_SYNC_TARGET_DIR="$CHECKOUT" bash "$SYNC" "$@"
}

# ── (1) Already-current checkout: clean no-op ───────────────────────────────
OUT="$(run_sync 2>&1)"; RC=$?
[[ "$RC" -eq 0 ]] || fail "already-current sync should exit 0, got $RC: $OUT"
grep -q '"kind":"checkout_sync_skipped"' "$CHECKOUT/.chump-locks/ambient.jsonl" \
    || fail "already-current sync should emit checkout_sync_skipped"
ok "already-current checkout is a clean idempotent no-op"

# ── (2) Merged script fix propagates to the stale checkout ─────────────────
# Simulate a second contributor pushing a "picker fix" directly to the bare
# origin (bypassing the checkout under test, as a real merged PR would).
SECOND="$TMP/second-clone"
git clone -q "$ORIGIN" "$SECOND"
(
    cd "$SECOND" || exit 1
    git config user.email "test2@example.com"
    git config user.name "Test2"
    git checkout -q main
    echo "v2 (picker fix)" > pick_gap.py
    git add pick_gap.py
    git commit -q -m "fix picker"
    git push -q origin main
)

OUT="$(run_sync 2>&1)"; RC=$?
[[ "$RC" -eq 0 ]] || fail "sync after upstream advance should exit 0, got $RC: $OUT"
[[ "$(cat "$CHECKOUT/pick_gap.py")" == "v2 (picker fix)" ]] \
    || fail "checkout did not fast-forward to the merged script fix"
grep -q '"kind":"checkout_synced"' "$CHECKOUT/.chump-locks/ambient.jsonl" \
    || fail "checkout_synced not emitted on successful sync"
ok "a merged script fix reaches the checkout via one sync run, no manual intervention"

# ── (3) Dirty tree: disposable runtime state never blocks sync ─────────────
mkdir -p "$SECOND/.chump"
(
    cd "$SECOND" || exit 1
    mkdir -p .chump
    echo "cache-v1" > .chump/github_cache.db
    git add .chump/github_cache.db
    git commit -q -m "seed disposable cache file (tracked, for test fixture)"
    git push -q origin main
)
run_sync >/dev/null 2>&1  # pick up the tracked file + commit first

(
    cd "$CHECKOUT" || exit 1
    echo "runtime-garbage-do-not-preserve" > .chump/github_cache.db
)
(
    cd "$SECOND" || exit 1
    echo "v3 (another fix)" > pick_gap.py
    git add pick_gap.py
    git commit -q -m "another fix"
    git push -q origin main
)

OUT="$(run_sync 2>&1)"; RC=$?
[[ "$RC" -eq 0 ]] || fail "dirty-disposable-state sync should exit 0, got $RC: $OUT"
[[ "$(cat "$CHECKOUT/pick_gap.py")" == "v3 (another fix)" ]] \
    || fail "disposable runtime state blocked the fast-forward"
ok "disposable runtime state (github_cache.db) never blocks the sync"

# ── (4) Dirty tree: legit local edit is stashed, not discarded ─────────────
(
    cd "$SECOND" || exit 1
    echo "v4 (yet another fix)" > pick_gap.py
    git add pick_gap.py
    git commit -q -m "yet another fix"
    git push -q origin main
)
(
    cd "$CHECKOUT" || exit 1
    echo "local operator note" >> README_LOCAL.md 2>/dev/null || echo "local operator note" > README_LOCAL.md
    git add README_LOCAL.md
)
# staged-but-uncommitted legit local file
OUT="$(run_sync 2>&1)"; RC=$?
[[ "$RC" -eq 0 ]] || fail "dirty-legit-edit sync should exit 0, got $RC: $OUT"
[[ "$(cat "$CHECKOUT/pick_gap.py")" == "v4 (yet another fix)" ]] \
    || fail "legit local edit blocked the fast-forward"
[[ -f "$CHECKOUT/README_LOCAL.md" ]] \
    || fail "legit local edit was discarded instead of stashed/restored"
grep -q '"kind":"checkout_sync_dirty_tree_protected"' "$CHECKOUT/.chump-locks/ambient.jsonl" \
    || fail "checkout_sync_dirty_tree_protected not emitted for the legit-edit case"
ok "legit local edits are stashed + restored (protected, not discarded)"

# ── (5) Non-main branch is never touched ────────────────────────────────────
FEATURE="$TMP/feature-checkout"
git clone -q "$ORIGIN" "$FEATURE"
(
    cd "$FEATURE" || exit 1
    git config user.email "test@example.com"
    git config user.name "Test"
    git checkout -q -b some-feature-branch
)
BEFORE_SHA="$(cd "$FEATURE" && git rev-parse HEAD)"
OUT="$(CHUMP_SYNC_TARGET_DIR="$FEATURE" bash "$SYNC" 2>&1)"; RC=$?
[[ "$RC" -eq 0 ]] || fail "non-main branch sync should exit 0 (clean skip), got $RC: $OUT"
AFTER_SHA="$(cd "$FEATURE" && git rev-parse HEAD)"
[[ "$BEFORE_SHA" == "$AFTER_SHA" ]] || fail "non-main branch checkout was mutated"
CUR_BRANCH_AFTER="$(cd "$FEATURE" && git rev-parse --abbrev-ref HEAD)"
[[ "$CUR_BRANCH_AFTER" == "some-feature-branch" ]] || fail "checkout was switched off its feature branch"
ok "a non-main checkout is never synced/switched"

echo
echo "All checkout-sync tests passed."
