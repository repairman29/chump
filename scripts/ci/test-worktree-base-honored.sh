#!/usr/bin/env bash
# test-worktree-base-honored.sh — INFRA-1053 acceptance test (AC #5).
#
# Verifies CHUMP_WORKTREE_BASE is honored across the product layer:
#   - chump claim Rust path (atomic_claim.rs)
#   - scripts/dispatch/worker.sh — wt_path uses the env base
#   - scripts/coord/worktree-prune.sh — WORKTREE_ROOT respects env
#   - scripts/ops/pr-repair-rebase.sh, queue-health-monitor.sh,
#     active-target-reaper.sh, stale-worktree-reaper.sh — base honored
#   - src/dashboard.rs path filter
#
# Allowed pattern: ${CHUMP_WORKTREE_BASE:-<legacy-default>}
# Disallowed: pure `.claude/worktrees/...` hardcodes in executable lines.

set -uo pipefail

PASS=0
FAIL=0
FAILS=()

ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); FAILS+=("$1"); }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

echo "=== INFRA-1053 CHUMP_WORKTREE_BASE honored tests ==="

# (a) Rust: atomic_claim.rs already honors CHUMP_WORKTREE_BASE.
if grep -q 'CHUMP_WORKTREE_BASE' "$REPO_ROOT/src/atomic_claim.rs"; then
    ok "atomic_claim.rs references CHUMP_WORKTREE_BASE"
else
    fail "atomic_claim.rs missing CHUMP_WORKTREE_BASE wiring"
fi

# (b) Product-layer shell scripts.
for f in \
    scripts/dispatch/worker.sh \
    scripts/coord/worktree-prune.sh \
    scripts/ops/pr-repair-rebase.sh \
    scripts/ops/queue-health-monitor.sh \
    scripts/ops/active-target-reaper.sh \
    scripts/ops/stale-worktree-reaper.sh
do
    if grep -q 'CHUMP_WORKTREE_BASE' "$REPO_ROOT/$f"; then
        ok "$f references CHUMP_WORKTREE_BASE"
    else
        fail "$f does NOT reference CHUMP_WORKTREE_BASE"
    fi
done

# (c) dashboard.rs filter.
if grep -q 'CHUMP_WORKTREE_BASE' "$REPO_ROOT/src/dashboard.rs"; then
    ok "src/dashboard.rs honors CHUMP_WORKTREE_BASE in path filter"
else
    fail "src/dashboard.rs does NOT honor CHUMP_WORKTREE_BASE"
fi

# (d) No pure hardcodes survive. Allow env-fallback form
# `${CHUMP_WORKTREE_BASE:-...}` and the documented WT_PARENT_OLD/NEW vars
# whose explicit purpose is to scan known legacy roots in parallel.
_remaining=$(grep -rn '\.claude/worktrees' \
    "$REPO_ROOT/src/dispatch.rs" \
    "$REPO_ROOT/src/dashboard.rs" \
    "$REPO_ROOT/scripts/coord/worktree-prune.sh" \
    "$REPO_ROOT/scripts/dispatch/worker.sh" \
    "$REPO_ROOT/scripts/ops/pr-repair-rebase.sh" \
    "$REPO_ROOT/scripts/ops/queue-health-monitor.sh" \
    "$REPO_ROOT/scripts/ops/active-target-reaper.sh" \
    "$REPO_ROOT/scripts/ops/stale-worktree-reaper.sh" \
    2>/dev/null \
    | grep -vE '^[^:]+:[0-9]+:[[:space:]]*[#/]' \
    | grep -vE 'INFRA-1053|legacy|convention|test fixture' \
    || true)
_remaining_exec=$(echo "$_remaining" \
    | grep -E '(=".*\.claude/worktrees|/\.claude/worktrees")' \
    | grep -v 'CHUMP_WORKTREE_BASE' \
    | grep -vE 'WT_PARENT_(OLD|NEW)=' \
    || true)
if [[ -z "$_remaining_exec" ]]; then
    ok "no pure executable hardcodes (env-fallback form is allowed)"
else
    fail "found pure executable hardcodes:"
    echo "$_remaining_exec" | head -8
fi

echo
echo "=== Summary: $PASS passed, $FAIL failed ==="
if (( FAIL > 0 )); then
    for f in "${FAILS[@]}"; do printf '  - %s\n' "$f"; done
    exit 1
fi
echo "PASS"
