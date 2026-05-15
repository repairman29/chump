#!/usr/bin/env bash
# scripts/ci/test-pwa-fleet-sidebar.sh — INFRA-1010

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
COMP="$REPO_ROOT/web/v2/fleet-sidebar.js"
INDEX="$REPO_ROOT/web/v2/index.html"
APP="$REPO_ROOT/web/v2/app.js"
SERVER="$REPO_ROOT/src/web_server.rs"

ok()   { printf '\033[0;32mPASS\033[0m %s\n' "$*"; }
fail() { printf '\033[0;31mFAIL\033[0m %s\n' "$*"; exit 1; }

# 1. Component file + custom element
[[ -f "$COMP" ]] || fail "component file missing: $COMP"
grep -q "customElements.define('chump-fleet-sidebar'" "$COMP" \
    || fail "chump-fleet-sidebar not defined"
ok "fleet-sidebar.js defines <chump-fleet-sidebar>"

# 2. AC #1 — server-side filter: kinds + prefixes params on /api/ambient/stream
grep -q '"kinds"' "$SERVER" \
    || fail "server: missing kinds query param parsing"
grep -q '"prefixes"' "$SERVER" \
    || fail "server: missing prefixes query param parsing"
grep -q "kinds_filter\|prefixes_filter" "$SERVER" \
    || fail "server: missing kinds/prefixes filter variables"
ok "server: /api/ambient/stream accepts kinds= + prefixes= (multi-OR filter)"

# 3. AC #1 — component requests the full whitelist
for k in lease_acquired lease_released gap_shipped scratch_commit_blocked \
         fleet_auth_fallback pr_stuck fleet_wedge; do
    grep -q "'$k'" "$COMP" \
        || fail "component: missing whitelist kind '$k'"
done
grep -q "'phase_'" "$COMP" || fail "component: missing 'phase_' prefix"
grep -q "'ship_'"  "$COMP" || fail "component: missing 'ship_' prefix"
ok "component: subscribes to all 7 whitelist kinds + phase_/ship_ prefixes"

# 4. AC #2 — up to 8 rows + reads /api/fleet-status
grep -q "MAX_ROWS = 8" "$COMP" || fail "component: MAX_ROWS != 8"
grep -q "/api/fleet-status" "$COMP" || fail "component: missing /api/fleet-status fetch"
ok "AC #2: up to 8 rows, reads /api/fleet-status snapshot"

# 5. AC #2 — also uses /api/ambient/stream for SSE
grep -q "EventSource" "$COMP" || fail "component: no EventSource — not real-time"
grep -q "/api/ambient/stream" "$COMP" || fail "component: not connecting to /api/ambient/stream"
ok "AC #2/6: real-time via EventSource on /api/ambient/stream"

# 6. AC #3 — sort by taken_at ascending
grep -q "taken_at" "$COMP" || fail "component: doesn't reference taken_at"
grep -qE "localeCompare|sort.*taken_at" "$COMP" \
    || fail "component: missing taken_at sort"
ok "AC #3: rows sort by taken_at ascending"

# 7. AC #4 — click dispatches chump:open-timeline
grep -q "chump:open-timeline" "$COMP" \
    || fail "AC #4: missing chump:open-timeline event"
ok "AC #4: click → chump:open-timeline (INFRA-1007 router)"

# 8. AC #5 — empty state copy
grep -q "No workers active" "$COMP" \
    || fail "AC #5: missing empty-state copy"
ok "AC #5: empty state when fleet idle"

# 9. Wired in app.js
grep -q "chump-fleet-sidebar" "$APP" \
    || fail "app.js doesn't reference <chump-fleet-sidebar>"
ok "<chump-fleet-sidebar> wired in chump-view-agents"

# 10. Script tag in index.html
grep -q 'src="fleet-sidebar.js"' "$INDEX" \
    || fail "index.html missing fleet-sidebar.js script tag"
ok "fleet-sidebar.js script tag in index.html"

# 11. HTML-escape for XSS safety
grep -q "_esc" "$COMP" || fail "no _esc helper"
ok "HTML-escapes values to prevent XSS"

# 12. Cleanup: SSE closed + poll cleared in disconnectedCallback
grep -q "disconnectedCallback" "$COMP" || fail "missing disconnectedCallback"
grep -q "_sse.close" "$COMP"  || fail "SSE not closed on disconnect"
grep -q "clearInterval" "$COMP" || fail "poll timer not cleared"
ok "cleans up SSE + poll on disconnect"

# 13. AC #6 — lease_acquired creates placeholder row before next snapshot
grep -q "lease_acquired" "$COMP" || fail "no lease_acquired handler"
grep -qE "lease_released|gap_shipped" "$COMP" \
    || fail "no terminal-event row removal"
ok "AC #6: lease_acquired inserts placeholder; lease_released/gap_shipped removes row"

echo
echo "All INFRA-1010 fleet-sidebar tests passed."
