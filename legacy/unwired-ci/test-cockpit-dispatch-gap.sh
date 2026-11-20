#!/usr/bin/env bash
# test-cockpit-dispatch-gap.sh — PRODUCT-130
#
# Verifies the Cockpit Fleet-zone Dispatch-gap action:
#   1. cockpit.js contains the PRODUCT-130 dispatch handler
#   2. Handler POSTs to /api/gap/work/<gap-id> (existing per gap_workflow_*)
#   3. Card variant for noWorkers + dispatchable-P1 surfaces [Dispatch <id>] as primary
#   4. Dispatchable selection filters: priority in (P0,P1), unclaimed, has AC
#   5. Card hides when no pickable P1 (AC #6: hint/disable for empty queue)
#   6. Endpoint /api/gap/work/{id} registered in web_server.rs

set -uo pipefail

PASS=0
FAIL=0
FAILS=()
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); FAILS+=("$1"); }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
COCKPIT="$REPO_ROOT/web/v2/cockpit.js"
WEB_SERVER="$REPO_ROOT/src/web_server.rs"

echo "=== PRODUCT-130 cockpit Dispatch-gap button tests ==="

[[ -f "$COCKPIT" ]] || { echo "FAIL: $COCKPIT missing"; exit 2; }

# ── AC #1: handler block exists and is gap-tagged ────────────────────────────
if grep -q "PRODUCT-130 — Dispatch top-priority gap" "$COCKPIT"; then
    ok "AC #1: dispatch-gap handler block present + gap-tagged"
else
    fail "AC #1: missing PRODUCT-130 handler block"
fi

# Scope the handler search via grep -A line window.
handler_block="$(grep -A20 "PRODUCT-130 — Dispatch top-priority gap" "$COCKPIT")"

# ── AC #4: handler POSTs to /api/gap/work/<id> ──────────────────────────────
if echo "$handler_block" | grep -q "/api/gap/work/" \
   && echo "$handler_block" | grep -q "method: 'POST'"; then
    ok "AC #4: dispatch POSTs /api/gap/work/<id>"
else
    fail "AC #4: dispatch missing POST to /api/gap/work/<id>"
fi

# ── AC #5: success state shows 'Dispatched <id>' ─────────────────────────────
if echo "$handler_block" | grep -q "Dispatched"; then
    ok "AC #5: success state shows 'Dispatched <id>' confirmation"
else
    fail "AC #5: no success-state confirmation"
fi

# ── AC #1/2/3: card variant for noWorkers + dispatchable-P1 ──────────────────
card_block="$(awk '/Card 1c: No workers \+ queue has P1/,/^    \/\/ Card 1d|^    \/\/ Card 2/' "$COCKPIT")"

# ── AC #2: filters priority P1 or P0 ────────────────────────────────────────
if echo "$card_block" | grep -q "g.priority === 'P1' || g.priority === 'P0'"; then
    ok "AC #2: dispatchable filtered to P1/P0"
else
    fail "AC #2: priority filter missing or wrong shape"
fi

# ── AC #6 (implicit): filters out claimed/assigned gaps ─────────────────────
if echo "$card_block" | grep -q "!g.claimed_by && !g.assignee"; then
    ok "AC #6: dispatchable filtered to unclaimed/unassigned"
else
    fail "AC #6: claim-filter missing"
fi

# ── AC #6: must have non-empty acceptance_criteria ──────────────────────────
if echo "$card_block" | grep -q "acceptance_criteria.*length > 0"; then
    ok "AC #6: dispatchable requires non-empty acceptance_criteria"
else
    fail "AC #6: AC presence filter missing"
fi

# ── AC #3: primary [Dispatch <id>] button ───────────────────────────────────
if echo "$card_block" | grep -qE "Dispatch \\\$\\{dispatchable.id\\}.*primary: true"; then
    ok "AC #3: card uses [Dispatch <id>] as primary CTA"
else
    fail "AC #3: [Dispatch <id>] not primary"
fi

# ── AC #1: card only shows when noWorkers + dispatchable ────────────────────
if echo "$card_block" | grep -q "if (noWorkers && dispatchable)"; then
    ok "AC #1: card gated on (noWorkers && dispatchable)"
else
    fail "AC #1: card gating logic missing"
fi

# ── AC #4 endpoint exists in web_server.rs ──────────────────────────────────
if [[ -f "$WEB_SERVER" ]] && grep -qE '"/api/gap/work/\{id\}"' "$WEB_SERVER"; then
    ok "/api/gap/work/{id} endpoint registered in web_server.rs"
else
    fail "/api/gap/work/{id} endpoint NOT registered — dispatch would 404"
fi

echo
echo "=== Summary: $PASS passed, $FAIL failed ==="
if (( FAIL > 0 )); then
    for f in "${FAILS[@]}"; do printf '  - %s\n' "$f"; done
    exit 1
fi
echo "PASS"
