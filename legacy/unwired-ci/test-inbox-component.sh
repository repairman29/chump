#!/usr/bin/env bash
# scripts/ci/test-inbox-component.sh — PRODUCT-104

set -uo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd -P)"
JS="$REPO_ROOT/web/v2/inbox.js"
HTML="$REPO_ROOT/web/v2/index.html"
ok()   { printf '\033[0;32mPASS\033[0m %s\n' "$*"; }
fail() { printf '\033[0;31mFAIL\033[0m %s\n' "$*"; exit 1; }
[ -f "$JS" ] || fail "inbox.js missing"

grep -q "customElements.define('chump-inbox'" "$JS" \
    || fail "must define <chump-inbox>"
ok "<chump-inbox> custom element defined"

grep -q 'src="inbox.js"' "$HTML" \
    || fail "inbox.js not registered in index.html"
ok "inbox.js script tag in index.html"

# Polls /api/inbox/<id>
grep -q "/api/inbox/" "$JS" \
    || fail "must poll /api/inbox/<id>"
ok "polls /api/inbox/<operator-id>"

# Sends ack via /api/inbox/<id>/ack
grep -q "/ack" "$JS" \
    || fail "must POST /api/inbox/<id>/ack"
ok "ack endpoint integrated"

# Emits via /api/broadcast for Take-it / Accept / vote actions
grep -q "/api/broadcast" "$JS" \
    || fail "reply actions must POST /api/broadcast"
ok "reply actions hit /api/broadcast"

# Contextual buttons per event type
grep -q "Take it" "$JS" || fail "STUCK row must surface Take-it button"
grep -q "Accept" "$JS" || fail "HANDOFF row must surface Accept"
grep -q "vote-plus" "$JS" && grep -q "vote-minus" "$JS" || fail "preference must surface +1/-1"
ok "contextual buttons: Take-it / Accept / vote-+1/-1"

# Operator-id resolution
grep -q "operator_id" "$JS" || fail "must resolve operator-id"
ok "operator-id resolution present"

# Polling cadence
grep -q "POLL_MS\b" "$JS" && grep -q "setInterval" "$JS" \
    || fail "must poll on an interval"
ok "polling timer configured"

echo
echo "All PRODUCT-104 chump-inbox smoke tests passed."
