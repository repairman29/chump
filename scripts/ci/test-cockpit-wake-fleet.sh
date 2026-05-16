#!/usr/bin/env bash
# test-cockpit-wake-fleet.sh — PRODUCT-128
#
# Verifies the Cockpit Today's-arc card's Wake-fleet action:
#   1. cockpit.js contains the PRODUCT-128 wake-fleet handler
#   2. Handler POSTs to /api/autopilot/start (existing endpoint per PRODUCT-115)
#   3. Card variant for ships=0 + autopilot=off uses [Wake fleet] as primary
#   4. Card variant for ships=0 + autopilot=on shows a DIFFERENT action
#      (currently 'Stop + restart' — picker-wedged diff diagnosis)
#   5. Button state machine handles success ('Autopilot starting' confirmation)
#      and failure (re-enable + error message restore)

set -uo pipefail

PASS=0
FAIL=0
FAILS=()
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); FAILS+=("$1"); }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
COCKPIT="$REPO_ROOT/web/v2/cockpit.js"

echo "=== PRODUCT-128 cockpit Wake-fleet button tests ==="

[[ -f "$COCKPIT" ]] || { echo "FAIL: $COCKPIT missing"; exit 2; }

# ── AC #1: handler block exists and is tagged with the gap id ────────────────
if grep -q "PRODUCT-128 — Wake-fleet button on Today's-arc card" "$COCKPIT"; then
    ok "AC #1: wake-fleet handler block present + gap-tagged"
else
    fail "AC #1: missing PRODUCT-128 handler block"
fi

# ── AC #3: handler POSTs to /api/autopilot/start ─────────────────────────────
# Pull the lines between the handler comment and `return` to scope the search.
handler_block="$(awk '/PRODUCT-128.*Wake-fleet/,/^    if .view === .restart-fleet./' "$COCKPIT")"
if echo "$handler_block" | grep -q "fetch('/api/autopilot/start'.*method: 'POST'"; then
    ok "AC #3: wake-fleet POSTs /api/autopilot/start"
else
    fail "AC #3: wake-fleet missing POST to /api/autopilot/start"
fi

# ── AC #4: success state shows 'Autopilot starting' confirmation ─────────────
if echo "$handler_block" | grep -q "Autopilot starting"; then
    ok "AC #4: success state shows 'Autopilot starting' confirmation"
else
    fail "AC #4: no success-state confirmation text"
fi

# ── AC #4: failure path re-enables + restores label ──────────────────────────
if echo "$handler_block" | grep -q "btn.disabled = false" \
   && echo "$handler_block" | grep -q "Wake fleet"; then
    ok "AC #4: failure path re-enables button + restores 'Wake fleet' label"
else
    fail "AC #4: failure path missing button-restore logic"
fi

# ── AC #2: ships=0 + autopilot=off card variant uses [Wake fleet] primary ───
# The 'else if (!autopilotRunning)' branch renders the wake-fleet card.
# Search a wider window (the cards.push() spans ~12 lines).
if grep -A12 "else if (!autopilotRunning)" "$COCKPIT" \
   | grep -q "Wake fleet.*primary: true"; then
    ok "AC #2: idle+off card uses [Wake fleet] as primary CTA"
else
    fail "AC #2: idle+off card not wired to [Wake fleet]"
fi

# ── AC #5: ships=0 + autopilot=on shows different action ────────────────────
# Should NOT propose 'Wake fleet' when autopilot is already running — it would
# do nothing useful. Currently we show 'Stop + restart'.
if grep -B1 -A8 "zero ships (autopilot on)" "$COCKPIT" \
   | grep -q "Stop + restart"; then
    ok "AC #5: idle+on card surfaces 'Stop + restart' (diff diagnosis)"
else
    fail "AC #5: idle+on card not surfacing distinct action"
fi

# ── Detection: card surfaces 'Fleet idle' wording ────────────────────────────
# The AC description called for 'Fleet idle — wake autopilot?' read; we use
# 'zero ships, autopilot off' + 'Fleet is parked' for clarity. Accept either.
if grep -qE "Fleet is parked|Fleet idle|zero ships.*autopilot off" "$COCKPIT"; then
    ok "ships=0 read text present"
else
    fail "Today's-arc card missing fleet-idle read text"
fi

# ── Wired to existing /api/autopilot/start (no new endpoint required) ────────
# Confirm the endpoint already exists in the Rust server so the button has
# something to call. PRODUCT-115 shipped this.
WEB_SERVER="$REPO_ROOT/src/web_server.rs"
if [[ -f "$WEB_SERVER" ]] && grep -q '"/api/autopilot/start"' "$WEB_SERVER"; then
    ok "/api/autopilot/start endpoint registered in web_server.rs (PRODUCT-115)"
else
    fail "/api/autopilot/start endpoint NOT registered — button would 404"
fi

echo
echo "=== Summary: $PASS passed, $FAIL failed ==="
if (( FAIL > 0 )); then
    for f in "${FAILS[@]}"; do printf '  - %s\n' "$f"; done
    exit 1
fi
echo "PASS"
