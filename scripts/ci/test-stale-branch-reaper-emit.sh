#!/usr/bin/env bash
# scripts/ci/test-stale-branch-reaper-emit.sh — INFRA-1453
#
# Verifies that scripts/ops/stale-branch-reaper.sh emits kind=branch_reaped
# per-deletion event (INFRA-1453) AND has the per-run reaper_run summary
# fire path intact (INFRA-120 unchanged).

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd -P)"
REAPER="$REPO_ROOT/scripts/ops/stale-branch-reaper.sh"
REGISTRY="$REPO_ROOT/docs/observability/EVENT_REGISTRY.yaml"

PASS=0
FAIL=0
ok()   { printf '\033[0;32mPASS\033[0m %s\n' "$*"; PASS=$((PASS+1)); }
fail() { printf '\033[0;31mFAIL\033[0m %s\n' "$*" >&2; FAIL=$((FAIL+1)); }

echo "=== INFRA-1453 branch-reaper per-deletion emit ==="
echo

# ── 1. Static wiring ────────────────────────────────────────────────────────
grep -q "INFRA-1453" "$REAPER" \
    && ok "INFRA-1453 marker present in reaper script" \
    || fail "INFRA-1453 marker missing"

grep -q 'kind":"branch_reaped"' "$REAPER" \
    && ok "kind=branch_reaped emit wired into reaper script" \
    || fail "branch_reaped emit missing"

grep -q "reaper_run_id" "$REAPER" \
    && ok "reaper_run_id field included for run-correlation" \
    || fail "reaper_run_id field missing"

grep -q "reaper_finish ok" "$REAPER" \
    && ok "reaper_finish ok summary still present (INFRA-120 preserved)" \
    || fail "reaper_finish summary missing — INFRA-120 regressed"

# ── 2. EVENT_REGISTRY registration ──────────────────────────────────────────
grep -q "^  - kind: branch_reaped$" "$REGISTRY" \
    && ok "branch_reaped registered in EVENT_REGISTRY.yaml" \
    || fail "branch_reaped missing from EVENT_REGISTRY.yaml"

# Ensure required fields documented
grep -A6 "^  - kind: branch_reaped$" "$REGISTRY" | grep -q "fields_required.*branch.*age_days.*reaper_run_id" \
    && ok "fields_required schema documented" \
    || fail "fields_required schema incomplete"

# ── 3. Emit is INSIDE the EXECUTE=1 branch (don't emit on dry runs) ─────────
awk '/EXECUTE -eq 1/,/^    else/' "$REAPER" | grep -q "branch_reaped" \
    && ok "branch_reaped emits only when EXECUTE=1 (no dry-run noise)" \
    || fail "branch_reaped should not fire on dry runs"

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
