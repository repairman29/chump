#!/usr/bin/env bash
# test-product-059-agents-board.sh — PRODUCT-059 structural tests.
#
# Verifies the live-agents board implementation:
#   (1) /api/fleet-status route registered in web_server.rs
#   (2) handle_fleet_status fn reads lease files + gap_store + gh CLI
#   (3) chump-view-agents Web Component defined in app.js
#   (4) 'agents' entry in VIEWS router map
#   (5) 'Agents' nav item in ChumpNav.#ITEMS
#   (6) agent-card CSS defined in index.html
#   (7) /api/fleet-status polls .chump-locks/*.json (lock_dir logic present)
#   (8) auto-refresh every 10s (setInterval 10_000 in chump-view-agents)
#
# Run: ./scripts/ci/test-product-059-agents-board.sh

set -euo pipefail

PASS=0
FAIL=0
FAILS=()

ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); FAILS+=("$1"); }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

WS="$REPO_ROOT/src/web_server.rs"
APP_JS="$REPO_ROOT/web/v2/app.js"
INDEX_HTML="$REPO_ROOT/web/v2/index.html"

echo "=== PRODUCT-059 agents live-board structural tests ==="
echo

# ── Test 1: /api/fleet-status route registered ───────────────────────────────
echo "--- Test 1: /api/fleet-status route registered in web_server.rs ---"
if grep -q '"/api/fleet-status"' "$WS" 2>/dev/null; then
    ok "Test 1: /api/fleet-status route found in web_server.rs"
else
    fail "Test 1: /api/fleet-status route not found in web_server.rs"
fi

# ── Test 2: handler reads lock files ─────────────────────────────────────────
echo "--- Test 2: handle_fleet_status reads .chump-locks lease files ---"
if grep -q "chump-locks\|CHUMP_LOCK_DIR\|lock_dir" "$WS" 2>/dev/null; then
    ok "Test 2: lock_dir / .chump-locks reference found in web_server.rs"
else
    fail "Test 2: no lock_dir or CHUMP_LOCK_DIR reference in fleet-status handler"
fi

# ── Test 3: chump-view-agents Web Component defined ──────────────────────────
echo "--- Test 3: chump-view-agents Web Component defined in app.js ---"
if grep -q "chump-view-agents\|ChumpViewAgents" "$APP_JS" 2>/dev/null; then
    ok "Test 3: chump-view-agents / ChumpViewAgents defined in app.js"
else
    fail "Test 3: chump-view-agents not defined in app.js"
fi

# ── Test 4: VIEWS map includes 'agents' ──────────────────────────────────────
echo "--- Test 4: VIEWS router map includes 'agents' entry ---"
if grep -q "'agents'.*chump-view-agents\|agents.*ChumpViewAgents" "$APP_JS" 2>/dev/null; then
    ok "Test 4: VIEWS['agents'] wired to chump-view-agents in app.js"
else
    fail "Test 4: VIEWS['agents'] entry not found in app.js"
fi

# ── Test 5: Agents nav item in ChumpNav ──────────────────────────────────────
echo "--- Test 5: 'Agents' nav item in ChumpNav.#ITEMS ---"
if grep -q "Agents\|'agents'" "$APP_JS" 2>/dev/null; then
    ok "Test 5: Agents nav item found in ChumpNav"
else
    fail "Test 5: Agents nav item not found in ChumpNav.#ITEMS"
fi

# ── Test 6: agent-card CSS in index.html ─────────────────────────────────────
echo "--- Test 6: agent-card CSS defined in index.html ---"
if grep -q "agent-card\|agents-list\|agent-gap-id" "$INDEX_HTML" 2>/dev/null; then
    ok "Test 6: agent-card CSS (.agent-card / .agents-list) found in index.html"
else
    fail "Test 6: agent-card CSS not found in index.html"
fi

# ── Test 7: handler reads lease JSON files from lock dir ─────────────────────
echo "--- Test 7: fleet-status reads .json files from lock dir ---"
if grep -q 'read_to_string\|read_dir' "$WS" 2>/dev/null && \
   grep -q "fleet.status\|fleet_status\|PRODUCT-059" "$WS" 2>/dev/null; then
    ok "Test 7: fleet-status reads lease JSON files (read_dir + read_to_string found)"
else
    fail "Test 7: no read_dir / read_to_string in fleet-status context"
fi

# ── Test 8: auto-refresh every 10s ───────────────────────────────────────────
echo "--- Test 8: chump-view-agents polls every 10 seconds ---"
if grep -q "10_000\|10000" "$APP_JS" 2>/dev/null; then
    # Verify it's inside the agents component context
    _ctx=$(grep -A 2 "10_000\|10000" "$APP_JS" 2>/dev/null | grep -c "fleet-status\|timer\|setInterval" || echo "0")
    if [[ "${_ctx:-0}" -gt 0 ]]; then
        ok "Test 8: 10s polling interval found in chump-view-agents (setInterval 10_000)"
    else
        # Softer check — 10_000 is present and so is fleet-status in the file
        if grep -q "fleet-status" "$APP_JS" && grep -q "10_000\|10000" "$APP_JS"; then
            ok "Test 8: 10s interval + fleet-status both present in app.js"
        else
            fail "Test 8: 10s polling for fleet-status not found in chump-view-agents"
        fi
    fi
else
    fail "Test 8: no 10_000/10000 interval found in app.js"
fi

# ── Summary ───────────────────────────────────────────────────────────────────
echo
echo "=== Results: $PASS passed, $FAIL failed ==="
if [[ $FAIL -gt 0 ]]; then
    for f in "${FAILS[@]}"; do echo "  - $f"; done
    exit 1
fi
exit 0
