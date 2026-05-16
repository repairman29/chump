#!/usr/bin/env bash
# test-cockpit-repair-drift.sh — PRODUCT-127
#
# Verifies the Cockpit gap-store-drift collapse + Repair action:
#   1. cockpit.js detects drift (gap with closed_pr AND status=open)
#   2. Card 1b 'Gap-store drift' shows ONE collapsed row (≥3 drift gaps)
#      instead of 20× identical attention rows
#   3. Primary action 'Copy repair command' / 'Repair drift' fires the
#      PRODUCT-127 handler which POSTs /api/gap/dep-clean
#   4. Handler has clipboard fallback when endpoint is 404 (binary not yet
#      rebuilt with the endpoint)
#   5. Success state shows 'Repaired N drift rows' confirmation

set -uo pipefail

PASS=0
FAIL=0
FAILS=()
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); FAILS+=("$1"); }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
COCKPIT="$REPO_ROOT/web/v2/cockpit.js"

echo "=== PRODUCT-127 cockpit Repair-drift card tests ==="

[[ -f "$COCKPIT" ]] || { echo "FAIL: $COCKPIT missing"; exit 2; }

# ── AC #1: drift detection (closed_pr set + status=open) ────────────────────
if grep -q "g.closed_pr && (g.status || 'open') === 'open'" "$COCKPIT"; then
    ok "AC #1: drift detection — gaps with closed_pr AND status=open"
else
    fail "AC #1: drift detection logic missing"
fi

# ── AC #2: collapses ≥3 drift gaps into a single card ───────────────────────
if grep -q "driftGaps.length >= 3" "$COCKPIT"; then
    ok "AC #2: drift card gated on ≥3 instances (collapse threshold)"
else
    fail "AC #2: drift-card collapse threshold missing"
fi

# ── AC #3: card title surfaces ONE row with count ───────────────────────────
if grep -q "Gap-store drift — \${driftGaps.length} gaps shipped but state.db still 'open'" "$COCKPIT"; then
    ok "AC #3: card title surfaces 'N gaps shipped' single-row summary"
else
    fail "AC #3: card title not in collapsed-summary shape"
fi

# ── AC #4: PRODUCT-127 handler block exists + gap-tagged ───────────────────
if grep -q "PRODUCT-127 — Real /api/gap/dep-clean wire" "$COCKPIT"; then
    ok "AC #4: dep-clean handler block present + gap-tagged"
else
    fail "AC #4: missing PRODUCT-127 handler block"
fi

# Scope: pull the handler body for downstream assertions.
handler_block="$(grep -A24 "PRODUCT-127 — Real /api/gap/dep-clean wire" "$COCKPIT")"

# ── AC #4: handler POSTs to /api/gap/dep-clean ──────────────────────────────
if echo "$handler_block" | grep -q "/api/gap/dep-clean" \
   && echo "$handler_block" | grep -q "method: 'POST'"; then
    ok "AC #4: dep-clean POSTs /api/gap/dep-clean"
else
    fail "AC #4: missing POST to /api/gap/dep-clean"
fi

# ── Robustness: clipboard fallback when endpoint is 404 ─────────────────────
if echo "$handler_block" | grep -q "navigator.clipboard.writeText" \
   && echo "$handler_block" | grep -q "chump gap dep-clean --apply"; then
    ok "clipboard fallback present (404 — endpoint not yet built)"
else
    fail "clipboard fallback missing — would hard-fail if binary not rebuilt"
fi

# ── AC #5: success state shows 'Repaired N drift rows' ──────────────────────
if echo "$handler_block" | grep -q "Repaired"; then
    ok "AC #5: success state shows 'Repaired N drift rows' confirmation"
else
    fail "AC #5: no success-state confirmation"
fi

# ── Card's primary action wires to the handler view ─────────────────────────
card_block="$(grep -A12 "Gap-store drift" "$COCKPIT")"
if echo "$card_block" | grep -q "Copy repair command.*primary: true\|Repair drift.*primary: true"; then
    ok "drift card uses Repair / Copy-repair as primary CTA"
else
    fail "drift card primary action not wired"
fi

echo
echo "=== Summary: $PASS passed, $FAIL failed ==="
if (( FAIL > 0 )); then
    for f in "${FAILS[@]}"; do printf '  - %s\n' "$f"; done
    exit 1
fi
echo "PASS"
