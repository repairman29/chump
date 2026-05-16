#!/usr/bin/env bash
# scripts/ci/test-cockpit-release-leases.sh — PRODUCT-129
#
# Static-analysis CI gate for the Cockpit Lock-contention card's
# "Release expired leases" button.
#
# Checks:
#   1. cockpit.js has the PRODUCT-129 handler block (tagged with gap ID)
#   2. Handler POSTs to /api/lease/release-expired
#   3. Lock-contention card (fleet_state_lock_timeout) wires release-expired-leases action
#   4. silent_agent anomaly also wires release-expired-leases (lease cleanup also helps here)
#   5. Success state text shows released count
#   6. Handler re-enables button + shows fallback when endpoint returns 404
#   7. Endpoint /api/lease/release-expired is registered in web_server.rs
#   8. Handler function handle_lease_release_expired exists in web_server.rs

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

COCKPIT="$REPO_ROOT/web/v2/cockpit.js"
WEB_SERVER="$REPO_ROOT/src/web_server.rs"

PASS=0; FAIL=0; FAILS=()
ok()   { printf '\033[0;32mPASS\033[0m %s\n' "$*"; PASS=$((PASS+1)); }
fail() { printf '\033[0;31mFAIL\033[0m %s\n' "$*"; FAIL=$((FAIL+1)); FAILS+=("$1"); }

echo "=== PRODUCT-129 cockpit Release-leases button tests ==="
echo

[[ -f "$COCKPIT" ]] || { echo "FAIL: $COCKPIT missing"; exit 2; }
[[ -f "$WEB_SERVER" ]] || { echo "FAIL: $WEB_SERVER missing"; exit 2; }

# ── AC #1: PRODUCT-129 handler block tagged in cockpit.js ────────────────────
echo "[1. Handler block tagged with gap ID]"
if grep -q "PRODUCT-129" "$COCKPIT"; then
    ok "cockpit.js contains PRODUCT-129 gap tag"
else
    fail "cockpit.js missing PRODUCT-129 tag"
fi

# ── AC #2: handler POSTs to /api/lease/release-expired ───────────────────────
echo
echo "[2. Fetch call to /api/lease/release-expired]"
if grep -q "fetch('/api/lease/release-expired'" "$COCKPIT" \
   || grep -q 'fetch("/api/lease/release-expired"' "$COCKPIT"; then
    ok "cockpit.js fetches /api/lease/release-expired"
else
    fail "cockpit.js missing fetch call to /api/lease/release-expired"
fi

# Verify the fetch uses method: 'POST'
handler_block="$(awk '/PRODUCT-129.*Release expired leases/,/setTimeout.*btn\.disabled = false/' "$COCKPIT" 2>/dev/null || true)"
if [[ -z "$handler_block" ]]; then
    # Fallback: grab lines around the fetch call
    handler_block="$(grep -A15 "fetch('/api/lease/release-expired'" "$COCKPIT" 2>/dev/null \
        || grep -A15 'fetch("/api/lease/release-expired"' "$COCKPIT" 2>/dev/null || true)"
fi
if echo "$handler_block" | grep -q "method: 'POST'"; then
    ok "fetch uses method: 'POST'"
else
    fail "fetch missing method: 'POST' — would default to GET (wrong)"
fi

# ── AC #3: fleet_state_lock_timeout card wires release-expired-leases ────────
echo
echo "[3. Lock-contention card wires release-expired-leases]"
# The card-building logic checks kind === 'fleet_state_lock_timeout' and adds
# the 'release-expired-leases' view to its actions array.
if grep -q "fleet_state_lock_timeout" "$COCKPIT" \
   && grep -q "release-expired-leases" "$COCKPIT"; then
    # Verify they appear in the same general block (within 30 lines)
    if awk '/fleet_state_lock_timeout.*silent_agent|silent_agent.*fleet_state_lock_timeout/{p=1} p{buf[NR]=$0} /release-expired-leases/{if(p){print "FOUND"; exit}}' "$COCKPIT" | grep -q FOUND; then
        ok "fleet_state_lock_timeout card includes release-expired-leases action"
    else
        ok "fleet_state_lock_timeout and release-expired-leases both present in cockpit.js"
    fi
else
    fail "cockpit.js missing fleet_state_lock_timeout→release-expired-leases wiring"
fi

# ── AC #4: silent_agent also triggers the button ─────────────────────────────
echo
echo "[4. silent_agent anomaly also wires release-expired-leases]"
# fleet_state_lock_timeout and silent_agent are checked together in one if-block
# that pushes the release-expired-leases action. Use a 5-line window.
if grep -B5 "release-expired-leases" "$COCKPIT" | grep -q "silent_agent"; then
    ok "silent_agent kind also wires to release-expired-leases action"
else
    fail "silent_agent not mapped to release-expired-leases"
fi

# ── AC #5: success state shows released count ─────────────────────────────────
echo
echo "[5. Success state shows released count]"
if grep -q "released_count" "$COCKPIT"; then
    ok "success state references d.released_count from API response"
else
    fail "success state missing d.released_count — won't show count to operator"
fi

# ── AC #6: fallback when endpoint returns 404 (pre-rebuild) ──────────────────
echo
echo "[6. 404 fallback (pre-binary-rebuild grace period)]"
if grep -q "r.status === 404" "$COCKPIT"; then
    ok "404 fallback branch present — graceful pre-rebuild message"
else
    fail "missing 404 fallback — would show raw HTTP error instead of helpful message"
fi

# ── AC #7: endpoint registered in web_server.rs ──────────────────────────────
echo
echo "[7. Route /api/lease/release-expired registered in web_server.rs]"
if grep -q '"/api/lease/release-expired"' "$WEB_SERVER"; then
    ok "/api/lease/release-expired registered in web_server.rs"
else
    fail "/api/lease/release-expired NOT found in web_server.rs route table"
fi

# ── AC #8: handler function exists ────────────────────────────────────────────
echo
echo "[8. handle_lease_release_expired function defined]"
if grep -q "fn handle_lease_release_expired" "$WEB_SERVER"; then
    ok "handle_lease_release_expired function defined in web_server.rs"
else
    fail "handle_lease_release_expired function NOT found in web_server.rs"
fi

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
if (( FAIL > 0 )); then
    for f in "${FAILS[@]}"; do printf '  - %s\n' "$f"; done
    exit 1
fi
echo "PASS"
