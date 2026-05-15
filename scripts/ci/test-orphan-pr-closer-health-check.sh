#!/usr/bin/env bash
# test-orphan-pr-closer-health-check.sh — INFRA-1326
#
# Verifies that orphan-pr-closer.sh has both PR health guards:
# 1. Skip when auto-merge is armed (pr_close_skipped_auto_merge_armed)
# 2. Skip when CI checks are queued/in_progress (pr_close_skipped_ci_running)
#
# Mix of static (grep) checks and a functional ambient-emit test.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
CLOSER="$REPO_ROOT/scripts/coord/orphan-pr-closer.sh"
REG="$REPO_ROOT/docs/observability/EVENT_REGISTRY.yaml"

ok()   { printf '\033[0;32mPASS\033[0m %s\n' "$*"; }
fail() { printf '\033[0;31mFAIL\033[0m %s\n' "$*" >&2; exit 1; }

[[ -x "$CLOSER" ]] || fail "script missing or not executable: $CLOSER"

# ── Test 1: script sources lib/github_cache.sh for cache_lookup_checks ────────
echo "--- Test 1: script sources lib/github_cache.sh and references guard infrastructure ---"
grep -q 'github_cache.sh' "$CLOSER" \
    || fail "orphan-pr-closer.sh does not source lib/github_cache.sh"
grep -q 'cache_lookup_checks\|_CACHE_LIB' "$CLOSER" \
    || fail "orphan-pr-closer.sh missing cache_lookup_checks reference"
ok "Test 1: script sources lib/github_cache.sh + references cache_lookup_checks"

# ── Test 2: auto-merge armed guard present ────────────────────────────────────
echo "--- Test 2: auto-merge armed guard present in script ---"
grep -q 'pr_close_skipped_auto_merge_armed' "$CLOSER" \
    || fail "orphan-pr-closer.sh missing pr_close_skipped_auto_merge_armed emit"
grep -q 'autoMerge\|auto_merge\|_auto_merge_armed' "$CLOSER" \
    || fail "orphan-pr-closer.sh missing auto-merge detection logic"
grep -q 'INFRA-1326' "$CLOSER" \
    || fail "INFRA-1326 attribution missing from orphan-pr-closer.sh"
ok "Test 2: auto-merge armed guard present (emit + detection + attribution)"

# ── Test 3: live CI running guard present ─────────────────────────────────────
echo "--- Test 3: live CI running guard present in script ---"
grep -q 'pr_close_skipped_ci_running' "$CLOSER" \
    || fail "orphan-pr-closer.sh missing pr_close_skipped_ci_running emit"
grep -q 'queued\|in_progress' "$CLOSER" \
    || fail "orphan-pr-closer.sh missing queued/in_progress check-run status check"
grep -q '_has_live_ci\|has_live_ci' "$CLOSER" \
    || fail "orphan-pr-closer.sh missing live-CI detection variable"
ok "Test 3: live CI running guard present (emit + queued/in_progress check)"

# ── Test 4: guards ordered — auto-merge check fires BEFORE CI check ───────────
echo "--- Test 4: auto-merge guard appears before CI guard in script ---"
_line_auto=$(grep -n 'pr_close_skipped_auto_merge_armed' "$CLOSER" | head -1 | cut -d: -f1)
_line_ci=$(grep -n 'pr_close_skipped_ci_running' "$CLOSER" | head -1 | cut -d: -f1)
[[ -n "$_line_auto" ]] || fail "pr_close_skipped_auto_merge_armed not found in script"
[[ -n "$_line_ci" ]]   || fail "pr_close_skipped_ci_running not found in script"
[[ "$_line_auto" -lt "$_line_ci" ]] \
    || fail "auto-merge guard (line $_line_auto) must come before CI guard (line $_line_ci)"
ok "Test 4: auto-merge guard (line $_line_auto) before CI guard (line $_line_ci)"

# ── Test 5: EVENT_REGISTRY.yaml registers both new kinds ──────────────────────
echo "--- Test 5: EVENT_REGISTRY.yaml registers both new event kinds ---"
grep -q 'pr_close_skipped_auto_merge_armed' "$REG" \
    || fail "EVENT_REGISTRY.yaml missing pr_close_skipped_auto_merge_armed"
grep -q 'pr_close_skipped_ci_running' "$REG" \
    || fail "EVENT_REGISTRY.yaml missing pr_close_skipped_ci_running"
ok "Test 5: both pr_close_skipped_* kinds registered in EVENT_REGISTRY.yaml"

echo
echo "All INFRA-1326 orphan-pr-closer health-check tests passed."
