#!/usr/bin/env bash
# scripts/ci/test-inbox-notifications.sh — PRODUCT-105

set -uo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd -P)"
JS="$REPO_ROOT/web/v2/inbox-notifications.js"
HTML="$REPO_ROOT/web/v2/index.html"
ok()   { printf '\033[0;32mPASS\033[0m %s\n' "$*"; }
fail() { printf '\033[0;31mFAIL\033[0m %s\n' "$*"; exit 1; }
[ -f "$JS" ] || fail "inbox-notifications.js missing"

grep -q 'src="inbox-notifications.js"' "$HTML" \
    || fail "inbox-notifications.js not registered in index.html"
ok "inbox-notifications.js script tag in index.html"

grep -q "/api/inbox/.*unread-count" "$JS" \
    || fail "must poll /api/inbox/<id>/unread-count"
ok "polls unread-count endpoint"

grep -q "setBadge" "$JS" && grep -q "nav-inbox-link" "$JS" \
    || fail "must update badge on #nav-inbox-link"
ok "nav badge wiring present"

grep -q "showToast" "$JS" \
    || fail "must define showToast"
ok "toast renderer present"

grep -q "urgency.*now\|'now'" "$JS" \
    || fail "toast must gate on urgency=now"
ok "toast gates on urgency=now"

grep -q "CHUMP_NO_TOAST" "$JS" \
    || fail "must honor CHUMP_NO_TOAST opt-out"
ok "CHUMP_NO_TOAST opt-out present"

grep -q "POLL_MS" "$JS" && grep -q "setInterval" "$JS" \
    || fail "must run on an interval"
ok "polling timer configured"

# Toast must auto-dismiss after a timeout
grep -q "setTimeout.*dismiss\|setTimeout(dismiss" "$JS" \
    || fail "toast must auto-dismiss"
ok "toast auto-dismiss timer present"

# Operator-id resolution shared with inbox.js / fleet-message.js
grep -q "chump_operator_id" "$JS" \
    || fail "must use shared chump_operator_id key"
ok "operator-id key shared with inbox/fleet-message"

echo
echo "All PRODUCT-105 inbox-notifications smoke tests passed."
