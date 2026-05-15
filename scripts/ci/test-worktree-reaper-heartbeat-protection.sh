#!/usr/bin/env bash
# test-worktree-reaper-heartbeat-protection.sh — INFRA-1291
#
# Validates that both reapers:
#   1. Read CHUMP_LEASE_HEARTBEAT_TTL_S (not hardcoded 900) for lease freshness.
#   2. Emit kind=worktree_reap_protected (not just worktree_reaper_skipped_active)
#      when a worktree is protected by a fresh heartbeat.
#   3. EVENT_REGISTRY.yaml contains the worktree_reap_protected kind.

set -uo pipefail

PASS=0; FAIL=0; FAILS=()
ok()   { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); FAILS+=("$1"); }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
STALE_REAPER="$REPO_ROOT/scripts/ops/stale-worktree-reaper.sh"
ACTIVE_REAPER="$REPO_ROOT/scripts/ops/active-target-reaper.sh"
EVENT_REG="$REPO_ROOT/docs/observability/EVENT_REGISTRY.yaml"

echo "=== INFRA-1291 heartbeat-TTL protection tests ==="

# ── Test 1: stale-worktree-reaper uses CHUMP_LEASE_HEARTBEAT_TTL_S ───────────
if grep -q 'CHUMP_LEASE_HEARTBEAT_TTL_S' "$STALE_REAPER"; then
    ok "stale-worktree-reaper: CHUMP_LEASE_HEARTBEAT_TTL_S referenced"
else
    fail "stale-worktree-reaper: CHUMP_LEASE_HEARTBEAT_TTL_S not found"
fi

# ── Test 2: stale-worktree-reaper no longer hardcodes 900 in lease_is_fresh ──
# (The 900 in comments is OK; check the actual call site)
if grep 'lease_is_fresh' "$STALE_REAPER" | grep -qv 'CHUMP_LEASE_HEARTBEAT_TTL_S'; then
    fail "stale-worktree-reaper: lease_is_fresh still calls with hardcoded 900"
else
    ok "stale-worktree-reaper: lease_is_fresh uses configurable TTL"
fi

# ── Test 3: stale-worktree-reaper has _emit_worktree_reap_protected function ─
if grep -q '_emit_worktree_reap_protected' "$STALE_REAPER"; then
    ok "stale-worktree-reaper: _emit_worktree_reap_protected defined/called"
else
    fail "stale-worktree-reaper: _emit_worktree_reap_protected missing"
fi

# ── Test 4: stale-worktree-reaper emits worktree_reap_protected kind ─────────
if grep -q '"worktree_reap_protected"' "$STALE_REAPER"; then
    ok "stale-worktree-reaper: emits kind=worktree_reap_protected"
else
    fail "stale-worktree-reaper: kind=worktree_reap_protected not emitted"
fi

# ── Test 5: stale-worktree-reaper includes ttl_s field in emit ───────────────
if grep 'worktree_reap_protected' "$STALE_REAPER" | grep -q 'ttl_s'; then
    ok "stale-worktree-reaper: ttl_s field in event"
else
    fail "stale-worktree-reaper: ttl_s missing from worktree_reap_protected emit"
fi

# ── Test 6: active-target-reaper uses CHUMP_LEASE_HEARTBEAT_TTL_S ────────────
if grep -q 'CHUMP_LEASE_HEARTBEAT_TTL_S' "$ACTIVE_REAPER"; then
    ok "active-target-reaper: CHUMP_LEASE_HEARTBEAT_TTL_S referenced"
else
    fail "active-target-reaper: CHUMP_LEASE_HEARTBEAT_TTL_S not found"
fi

# ── Test 7: active-target-reaper no longer hardcodes 900 ─────────────────────
# 900 may appear in comments; check for the comparison line
if grep -E '^\s*\[\[ \$age_s -gt 900 \]\]' "$ACTIVE_REAPER" | grep -qv '#'; then
    fail "active-target-reaper: still hardcodes 900 in age_s comparison"
else
    ok "active-target-reaper: age_s comparison uses configurable TTL"
fi

# ── Test 8: active-target-reaper has _emit_worktree_reap_protected ───────────
if grep -q '_emit_worktree_reap_protected' "$ACTIVE_REAPER"; then
    ok "active-target-reaper: _emit_worktree_reap_protected defined/called"
else
    fail "active-target-reaper: _emit_worktree_reap_protected missing"
fi

# ── Test 9: active-target-reaper emits kind=worktree_reap_protected ──────────
if grep -q '"worktree_reap_protected"' "$ACTIVE_REAPER"; then
    ok "active-target-reaper: emits kind=worktree_reap_protected"
else
    fail "active-target-reaper: kind=worktree_reap_protected not emitted"
fi

# ── Test 10: EVENT_REGISTRY registers worktree_reap_protected ────────────────
if grep -q 'worktree_reap_protected' "$EVENT_REG"; then
    ok "EVENT_REGISTRY.yaml: worktree_reap_protected registered"
else
    fail "EVENT_REGISTRY.yaml: worktree_reap_protected NOT registered"
fi

# ── Test 11: EVENT_REGISTRY includes required fields for worktree_reap_protected
# Find the line number of the kind entry and check the next 15 lines for fields_required.
reg_start=$(grep -n 'kind: worktree_reap_protected' "$EVENT_REG" | head -1 | cut -d: -f1)
if [[ -n "$reg_start" ]]; then
    if awk "NR>=${reg_start} && NR<=$((reg_start+15))" "$EVENT_REG" | grep -q 'fields_required'; then
        ok "EVENT_REGISTRY.yaml: fields_required present for worktree_reap_protected"
    else
        fail "EVENT_REGISTRY.yaml: fields_required missing for worktree_reap_protected"
    fi
else
    fail "EVENT_REGISTRY.yaml: worktree_reap_protected kind entry not found (test 11)"
fi

# ── Test 12: INFRA-1291 attribution in stale-worktree-reaper ─────────────────
if grep -q 'INFRA-1291' "$STALE_REAPER"; then
    ok "stale-worktree-reaper: INFRA-1291 attribution present"
else
    fail "stale-worktree-reaper: INFRA-1291 attribution missing"
fi

# ── Test 13: INFRA-1291 attribution in active-target-reaper ──────────────────
if grep -q 'INFRA-1291' "$ACTIVE_REAPER"; then
    ok "active-target-reaper: INFRA-1291 attribution present"
else
    fail "active-target-reaper: INFRA-1291 attribution missing"
fi

# ── Test 14: stale-worktree-reaper emits worktree_reap_protected at is_active_lease ─
if grep -A 20 'is_active_lease' "$STALE_REAPER" | grep -q '_emit_worktree_reap_protected'; then
    ok "stale-worktree-reaper: worktree_reap_protected called at is_active_lease block"
else
    fail "stale-worktree-reaper: worktree_reap_protected not wired into is_active_lease block"
fi

# ── Test 15: active-target-reaper emits protected event before skipping ──────
if grep -B 5 '_emit_reaper_skipped.*active_lease' "$ACTIVE_REAPER" | grep -q '_emit_worktree_reap_protected'; then
    ok "active-target-reaper: worktree_reap_protected emitted before skip"
else
    fail "active-target-reaper: worktree_reap_protected not emitted before active_lease skip"
fi

echo
echo "=== Summary: $PASS passed, $FAIL failed ==="
if (( FAIL > 0 )); then
    for f in "${FAILS[@]}"; do printf '  - %s\n' "$f"; done
    exit 1
fi
echo "PASS"
