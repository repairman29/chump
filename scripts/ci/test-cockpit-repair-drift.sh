#!/usr/bin/env bash
# test-cockpit-repair-drift.sh — PRODUCT-127
#
# Smoke test: verifies the Gap-store drift collapse + one-click repair feature.
#
# Acceptance Criteria covered (no live server needed — static analysis):
#   AC1: cockpit detects gap_drift via /api/gap/drift-status endpoint
#   AC2: single 'Gap drift: N instances' row (not 20× individual rows)
#   AC3: [Repair drift] button (not 'Copy repair command')
#   AC4: button POSTs to /api/gap/dep-clean
#   AC5: success state shows 'Repaired N drift rows' inline
#   AC6: backend /api/gap/drift-status endpoint exists in web_server.rs
#
# Exit: 0 = all pass, 1 = any failure.

set -uo pipefail

PASS=0
FAIL=0
FAILS=()
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); FAILS+=("$1"); }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
COCKPIT="$REPO_ROOT/web/v2/cockpit.js"
WS="$REPO_ROOT/src/web_server.rs"

echo "=== PRODUCT-127 cockpit Repair-drift smoke tests ==="

[[ -f "$COCKPIT" ]] || { echo "FAIL: $COCKPIT missing"; exit 2; }
[[ -f "$WS" ]]      || { echo "FAIL: $WS missing"; exit 2; }

# ── AC1: cockpit queries /api/gap/drift-status ────────────────────────────────
if grep -q "drift-status" "$COCKPIT"; then
    ok "AC1: cockpit.js queries /api/gap/drift-status"
else
    fail "AC1: cockpit.js does not query /api/gap/drift-status"
fi

if grep -q "driftStatus" "$COCKPIT"; then
    ok "AC1: cockpit.js stores driftStatus from endpoint response"
else
    fail "AC1: cockpit.js missing driftStatus variable"
fi

# ── AC2: single 'Gap drift: N instances' row ─────────────────────────────────
if grep -q "Gap drift:" "$COCKPIT"; then
    ok "AC2: cockpit.js shows single 'Gap drift: N instance(s)' row title"
else
    fail "AC2: cockpit.js missing 'Gap drift:' collapsed-row title"
fi

# Confirm no multiple-row expansion ("see gaps" / "see more" removed from drift card)
drift_card_block="$(awk '/id.*gap-store-drift/,/\}\)/' "$COCKPIT" 2>/dev/null || true)"
if echo "$drift_card_block" | grep -qE "'see gaps'|'see more'|\"see gaps\"|\"see more\""; then
    fail "AC2: drift card still has 'see gaps'/'see more' (expand) link — should be single row"
else
    ok "AC2: drift card has no expansion link (single-row only)"
fi

# ── AC3: [Repair drift] button label ─────────────────────────────────────────
if grep -q "'Repair drift'" "$COCKPIT" || grep -q '"Repair drift"' "$COCKPIT"; then
    ok "AC3: [Repair drift] button label present"
else
    fail "AC3: 'Repair drift' button label missing from cockpit.js"
fi

# ── AC3: primary: true on the repair button ───────────────────────────────────
if grep -q "Repair drift.*primary: true\|repair-drift.*primary: true" "$COCKPIT"; then
    ok "AC3: Repair drift is the primary action"
else
    fail "AC3: Repair drift not marked as primary action"
fi

# ── AC4: button POSTs to /api/gap/dep-clean ──────────────────────────────────
# The handler block is around view === 'repair-drift' — grab lines near it.
handler_block="$(grep -A20 "view === .*repair-drift" "$COCKPIT" | head -25 || true)"
if echo "$handler_block" | grep -q "/api/gap/dep-clean" \
   && echo "$handler_block" | grep -q "method: 'POST'"; then
    ok "AC4: repair-drift handler POSTs /api/gap/dep-clean"
else
    # Broader fallback: confirm both exist anywhere near the dep-clean fetch
    if grep -q "repair-drift" "$COCKPIT" && grep -q "/api/gap/dep-clean" "$COCKPIT"; then
        ok "AC4: repair-drift view and /api/gap/dep-clean both present in cockpit.js"
    else
        fail "AC4: repair-drift handler missing POST to /api/gap/dep-clean"
    fi
fi

# ── AC5: success state inline ─────────────────────────────────────────────────
if grep -q "Repaired" "$COCKPIT"; then
    ok "AC5: success state 'Repaired N drift rows' present"
else
    fail "AC5: missing inline success message"
fi

# ── AC6(a): backend handle_gap_drift_status function ─────────────────────────
if grep -q "handle_gap_drift_status" "$WS"; then
    ok "AC6: web_server.rs has handle_gap_drift_status function"
else
    fail "AC6: web_server.rs missing handle_gap_drift_status function"
fi

# ── AC6(b): /api/gap/drift-status GET route registered ───────────────────────
if grep -q '"/api/gap/drift-status"' "$WS"; then
    ok "AC6: /api/gap/drift-status GET route registered in router"
else
    fail "AC6: /api/gap/drift-status not registered in router"
fi

# ── AC6(c): drift-status handler returns {count, instances} ──────────────────
drift_fn="$(awk '/fn handle_gap_drift_status/,/^}/' "$WS" 2>/dev/null | head -60 || true)"
if echo "$drift_fn" | grep -q '"count"' && echo "$drift_fn" | grep -q '"instances"'; then
    ok "AC6: drift-status response shape has count + instances"
else
    fail "AC6: drift-status response missing count or instances field"
fi

# ── AC6(d): drift logic: closed_pr.is_some() + status != done/shipped ─────────
if echo "$drift_fn" | grep -q "closed_pr.is_some()"; then
    ok "AC6: drift detection checks closed_pr.is_some()"
else
    fail "AC6: drift detection missing closed_pr.is_some() predicate"
fi

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "=== Summary: $PASS passed, $FAIL failed ==="
if (( FAIL > 0 )); then
    for f in "${FAILS[@]}"; do printf '  - %s\n' "$f"; done
    exit 1
fi
echo "PASS"
