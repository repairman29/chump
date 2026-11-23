#!/usr/bin/env bash
# scripts/ci/test-fleet-message-component.sh — PRODUCT-103
#
# Smoke checks for the <chump-fleet-message> Web Component. No real browser
# spin-up; we just verify the file exists, declares the custom element,
# and the script tag is registered in index.html. Functional rendering is
# covered by e2e-pwa tests once those are extended in a follow-up.

set -uo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd -P)"
JS="$REPO_ROOT/web/v2/fleet-message.js"
HTML="$REPO_ROOT/web/v2/index.html"
ok()   { printf '\033[0;32mPASS\033[0m %s\n' "$*"; }
fail() { printf '\033[0;31mFAIL\033[0m %s\n' "$*"; exit 1; }

[ -f "$JS" ]   || fail "fleet-message.js missing"
[ -f "$HTML" ] || fail "index.html missing"

# 1. File defines the custom element
grep -q "customElements.define('chump-fleet-message'" "$JS" \
    || fail "fleet-message.js must define 'chump-fleet-message' element"
ok "fleet-message.js defines <chump-fleet-message>"

# 2. Script tag registered in index.html
grep -q 'src="fleet-message.js"' "$HTML" \
    || fail "index.html must load fleet-message.js"
ok "index.html registers fleet-message.js"

# 3. POST target is /api/broadcast (INFRA-1296)
grep -q "/api/broadcast" "$JS" \
    || fail "compose form must POST to /api/broadcast"
ok "compose form targets /api/broadcast"

# 4. Loads active sessions from /api/fleet-status for recipient dropdown
grep -q "/api/fleet-status" "$JS" \
    || fail "compose form must populate recipient datalist from /api/fleet-status"
ok "compose form sources recipient list from /api/fleet-status"

# 5. Client-side validation prevents bad submissions (mirror of server checks)
grep -q "requires a subject" "$JS" \
    || fail "form should validate subject required for event types"
grep -q "requires a recipient" "$JS" \
    || fail "form should validate HANDOFF requires recipient"
grep -q "requires a kind" "$JS" \
    || fail "form should validate FEEDBACK/ALERT requires kind"
ok "client validation matches server requirements"

# 6. Urgency field is in the form
grep -q "urgency" "$JS" \
    || fail "compose form should expose urgency selector"
ok "urgency selector present"

# 7. FEEDBACK preference shows vote selector conditionally
grep -q "preference" "$JS" && grep -q "vote" "$JS" \
    || fail "FEEDBACK preference path must surface vote selector"
ok "FEEDBACK preference vote UI present"

echo
echo "All PRODUCT-103 chump-fleet-message smoke tests passed."
