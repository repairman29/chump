#!/usr/bin/env bash
# scripts/ci/test-pwa-autopilot-toggle.sh — PRODUCT-115
#
# Static + behavioral checks for the autopilot-toggle Web Component.
# No browser required; we verify the component's JS structure + the
# index.html wiring + the backing API endpoints exist.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
COMP="$REPO_ROOT/web/v2/autopilot-toggle.js"
INDEX="$REPO_ROOT/web/v2/index.html"
SERVER="$REPO_ROOT/src/web_server.rs"

ok()   { printf '\033[0;32mPASS\033[0m %s\n' "$*"; }
fail() { printf '\033[0;31mFAIL\033[0m %s\n' "$*"; exit 1; }

# 1. Component file exists + defines the custom element
[[ -f "$COMP" ]] || fail "component file missing: $COMP"
grep -q "customElements.define('chump-autopilot-toggle'" "$COMP" \
    || fail "chump-autopilot-toggle not defined via customElements.define"
ok "autopilot-toggle.js defines <chump-autopilot-toggle>"

# 2. Component wires the 3 endpoints
grep -q "/api/autopilot/status" "$COMP" || fail "missing /api/autopilot/status fetch"
grep -q "/api/autopilot/start"  "$COMP" || fail "missing /api/autopilot/start fetch"
grep -q "/api/autopilot/stop"   "$COMP" || fail "missing /api/autopilot/stop fetch"
ok "component wires all 3 /api/autopilot endpoints"

# 3. Component handles all 4 state colors (green/gray/amber/red)
grep -q "'running'"  "$COMP" || fail "missing running state branch"
grep -q "'stopped'"  "$COMP" || fail "missing stopped state branch"
grep -q "'starting'" "$COMP" || fail "missing starting state branch"
grep -q "'error'"    "$COMP" || fail "missing error state branch"
ok "component handles all 4 actual_state values"

# 4. 10s polling timer present
grep -qE "setInterval\(.*10[_]?000" "$COMP" || fail "missing 10s status polling"
ok "component polls /api/autopilot/status every 10s"

# 5. Auth headers wired (INFRA-1014 middleware compat)
grep -q "_authHeaders" "$COMP" || fail "no _authHeaders helper"
grep -q "X-Chump-Auth" "$COMP" || fail "X-Chump-Auth header not sent"
ok "component sends X-Chump-Auth header for INFRA-1014 middleware"

# 6. Ambient event emitted on toggle
grep -q "autopilot_toggled" "$COMP" || fail "missing autopilot_toggled ambient emit"
ok "component emits kind=autopilot_toggled on transition"

# 7. Pending-state guard (disable button during in-flight call)
grep -q "_pending" "$COMP" || fail "no _pending state guard"
grep -q "disabled" "$COMP" || fail "button not disabled during pending"
ok "component disables button during in-flight API call"

# 8. Disconnect cleanup
grep -q "disconnectedCallback" "$COMP" || fail "no disconnectedCallback (timer leak risk)"
grep -q "clearInterval" "$COMP" || fail "disconnectedCallback doesn't clear poll timer"
ok "component cleans up poll timer on disconnect"

# 9. index.html wiring: header includes the tag
grep -q "<chump-autopilot-toggle>" "$INDEX" \
    || fail "index.html header doesn't include <chump-autopilot-toggle>"
ok "<chump-autopilot-toggle> placed in index.html header"

# 10. index.html includes the script
grep -q 'src="autopilot-toggle.js"' "$INDEX" \
    || fail "index.html missing autopilot-toggle.js script tag"
ok "autopilot-toggle.js script tag in index.html"

# 11. Server-side endpoints exist (sanity — these landed pre-PRODUCT-115)
grep -q "/api/autopilot/status" "$SERVER" || fail "server endpoint /api/autopilot/status missing"
grep -q "/api/autopilot/start"  "$SERVER" || fail "server endpoint /api/autopilot/start missing"
grep -q "/api/autopilot/stop"   "$SERVER" || fail "server endpoint /api/autopilot/stop missing"
ok "all 3 server endpoints exist (no backend work needed)"

# 12. Pulsing animation on enabled state
grep -q "@keyframes pulse" "$COMP" || fail "no pulse animation defined"
ok "active autopilot shows pulsing indicator"

# 13. Accessibility: aria-pressed for toggle state
grep -q "aria-pressed" "$COMP" || fail "missing aria-pressed for screen readers"
grep -q "aria-label" "$COMP"   || fail "missing aria-label"
ok "component sets aria-pressed + aria-label"

echo
echo "All PRODUCT-115 autopilot-toggle tests passed."
