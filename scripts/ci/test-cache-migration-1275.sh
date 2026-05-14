#!/usr/bin/env bash
# scripts/ci/test-cache-migration-1275.sh — INFRA-1275
#
# Verifies that chump-ambient-glance.sh + gap-preflight.sh have ZERO raw `gh`
# calls (all routed through scripts/coord/lib/github_cache.sh helpers), and
# that the new lib helpers are sourced cleanly.
#
# Strategy: structural grep + source-test the library. The end-to-end behavior
# (cache hit returns rows, miss triggers refill) is exercised by callers
# during normal operation; this gate prevents regressions where someone adds
# a raw `gh pr list` back into the hot path.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
LIB="$REPO_ROOT/scripts/coord/lib/github_cache.sh"
GLANCE="$REPO_ROOT/scripts/coord/chump-ambient-glance.sh"
PREFLIGHT="$REPO_ROOT/scripts/coord/gap-preflight.sh"

ok()   { printf '\033[0;32mPASS\033[0m %s\n' "$*"; }
fail() { printf '\033[0;31mFAIL\033[0m %s\n' "$*"; exit 1; }

[[ -f "$LIB" ]]       || fail "missing $LIB"
[[ -f "$GLANCE" ]]    || fail "missing $GLANCE"
[[ -f "$PREFLIGHT" ]] || fail "missing $PREFLIGHT"

# ── Test 1: library exports the new helpers ─────────────────────────────────
# shellcheck source=/dev/null
SOURCED_FNS="$(bash -c "source '$LIB' && declare -F | awk '{print \$3}'")"
for fn in cache_query_open_prs cache_query_open_prs_by_title cache_refresh_open_prs cache_lookup_pr_files; do
    grep -q "^$fn$" <<< "$SOURCED_FNS" || fail "lib missing helper: $fn"
done
ok "github_cache.sh: 4 new INFRA-1275 helpers exported"

# ── Test 2: ambient-glance.sh has ZERO raw gh (non-comment) ────────────────
HITS_GLANCE="$(grep -nE '^[[:space:]]*[^#]*\bgh (api|pr|repo) ' "$GLANCE" || true)"
if [[ -n "$HITS_GLANCE" ]]; then
    fail "chump-ambient-glance.sh still has raw \`gh\` calls in executable lines:
$HITS_GLANCE"
fi
ok "ambient-glance.sh: 0 raw \`gh\` calls (all routed through lib)"

# ── Test 3: gap-preflight.sh has ZERO raw gh (non-comment) ─────────────────
HITS_PREFLIGHT="$(grep -nE '^[[:space:]]*[^#]*\bgh (api|pr |repo )' "$PREFLIGHT" || true)"
if [[ -n "$HITS_PREFLIGHT" ]]; then
    fail "gap-preflight.sh still has raw \`gh\` calls in executable lines:
$HITS_PREFLIGHT"
fi
ok "gap-preflight.sh: 0 raw \`gh\` calls (all routed through lib)"

# ── Test 4: both scripts source the cache lib ───────────────────────────────
grep -q "source.*github_cache.sh\|source \"\$_cache_lib" "$GLANCE" \
    || fail "ambient-glance.sh doesn't source github_cache.sh"
grep -q "source.*github_cache.sh\|source \"\$_cache_lib" "$PREFLIGHT" \
    || fail "gap-preflight.sh doesn't source github_cache.sh"
ok "both scripts source scripts/coord/lib/github_cache.sh"

# ── Test 5: REST-only fallback (no `gh pr list`, no GraphQL) in the lib ────
# cache_refresh_open_prs must use `gh api`, not `gh pr list`.
if grep -A30 "cache_refresh_open_prs()" "$LIB" | grep -q "gh pr list"; then
    fail "cache_refresh_open_prs uses 'gh pr list' (GraphQL); must use 'gh api' (REST)"
fi
grep -A30 "cache_refresh_open_prs()" "$LIB" | grep -q "gh api" \
    || fail "cache_refresh_open_prs missing 'gh api' REST call"
ok "cache_refresh_open_prs: REST path only (no GraphQL)"

# ── Test 6: background-tag applied to lib REST calls (INFRA-1080) ──────────
grep -A5 "cache_lookup_pr_files()" "$LIB" | grep -q "CHUMP_GH_CALL_CRITICALITY=background" \
    || fail "cache_lookup_pr_files missing CHUMP_GH_CALL_CRITICALITY=background tag"
grep -A30 "cache_refresh_open_prs()" "$LIB" | grep -q "CHUMP_GH_CALL_CRITICALITY=background" \
    || fail "cache_refresh_open_prs missing CHUMP_GH_CALL_CRITICALITY=background tag"
ok "lib REST calls tagged CHUMP_GH_CALL_CRITICALITY=background (INFRA-1080)"

# ── Test 7: title-substring helper escapes SQL single-quotes ───────────────
grep -A20 "cache_query_open_prs_by_title()" "$LIB" | grep -q "substr//\\\\'" \
    || fail "cache_query_open_prs_by_title doesn't escape SQL single-quotes — injection risk"
ok "cache_query_open_prs_by_title: SQL-injection guard present"

# ── Test 8: bash syntax check on all three files ────────────────────────────
bash -n "$LIB"        || fail "github_cache.sh has bash syntax errors"
bash -n "$GLANCE"     || fail "chump-ambient-glance.sh has bash syntax errors"
bash -n "$PREFLIGHT"  || fail "gap-preflight.sh has bash syntax errors"
ok "bash syntax: all three files parse clean"

# ── Test 9: CLAUDE.md Already-migrated section lists both scripts ───────────
CLAUDE_MD="$REPO_ROOT/CLAUDE.md"
# The "Already migrated:" paragraph names each migrated caller. Verify both
# strings appear within 200 chars of an INFRA-1275 reference.
ALREADY_MIGRATED_BLOCK="$(awk '/Already migrated:/,/Next consumers/' "$CLAUDE_MD")"
[[ "$ALREADY_MIGRATED_BLOCK" == *"chump-ambient-glance.sh"* ]] \
    || fail "CLAUDE.md Already-migrated section missing chump-ambient-glance.sh"
[[ "$ALREADY_MIGRATED_BLOCK" == *"gap-preflight.sh"* ]] \
    || fail "CLAUDE.md Already-migrated section missing gap-preflight.sh"
[[ "$ALREADY_MIGRATED_BLOCK" == *"INFRA-1275"* ]] \
    || fail "CLAUDE.md Already-migrated section missing INFRA-1275 tag"
ok "CLAUDE.md: both scripts listed under Already-migrated"

ok "ALL INFRA-1275 cache-migration checks passed"
