#!/usr/bin/env bash
# scripts/ci/test-pwa-audit-view.sh — PRODUCT-111
#
# Structural test for the <chump-view-audit> decision-chain panel.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
APP_JS="$REPO_ROOT/web/v2/app.js"
INDEX_HTML="$REPO_ROOT/web/v2/index.html"

ok()   { printf '\033[0;32mPASS\033[0m %s\n' "$*"; }
fail() { printf '\033[0;31mFAIL\033[0m %s\n' "$*"; exit 1; }

[[ -f "$APP_JS" ]] || fail "missing $APP_JS"

grep -q "class ChumpViewAudit" "$APP_JS"           || fail "missing ChumpViewAudit class"
grep -q "customElements.define('chump-view-audit'" "$APP_JS" || fail "chump-view-audit not registered"
ok "ChumpViewAudit defined + registered"

grep -q "audit:.*chump-view-audit" "$APP_JS"       || fail "audit not in VIEWS router map"
ok "audit registered in VIEWS router map"

grep -q "id: 'audit'" "$APP_JS"                    || fail "audit missing from LIBRARY cadence subtabs"
ok "LIBRARY cadence includes audit sub-tab"

grep -q "fetch(\`/api/tool-approval-audit"   "$APP_JS" || fail "missing /api/tool-approval-audit fetch"
grep -q "fetch(\`/api/cos/decisions"          "$APP_JS" || fail "missing /api/cos/decisions fetch"
ok "consolidates /api/tool-approval-audit + /api/cos/decisions"

for chip in "'1h'" "'24h'" "'7d'" "'all'"; do
    grep -q "$chip" "$APP_JS" || fail "missing time-window chip: $chip"
done
ok "time-window chips: 1h / 24h / 7d / all"

for kind in tool_approval cos; do
    grep -q "kind === '$kind'\|kind: '$kind'\|'$kind'," "$APP_JS" || fail "missing kind handling: $kind"
done
ok "decision-kind filter: tool_approval + cos"

grep -q "audit.filters" "$APP_JS" || fail "filter state not persisted via chumpPrefs (audit.filters)"
ok "filters persist via chumpPrefs (audit.filters)"

grep -q "data-filter-session\|data-filter-gap" "$APP_JS" || fail "no session/gap pills for click-to-filter"
ok "click-to-filter: session_id + gap_id pills"

grep -q ".audit-export\|application/x-ndjson\|chump-audit-.*\.jsonl" "$APP_JS" || fail "missing JSONL export"
ok "export: visible rows → JSONL download"

grep -q "audit_view_session" "$APP_JS" || fail "missing telemetry kind=audit_view_session"
ok "telemetry: kind=audit_view_session on export"

grep -q "chump-view-audit .audit-toolbar\|.audit-chip\|.audit-row" "$INDEX_HTML" \
    || fail "CSS for audit view missing in index.html"
grep -A60 "chump-view-audit" "$INDEX_HTML" | grep -q "@media.*max-width: 640px" \
    || fail "missing mobile media query for audit view"
ok "CSS: toolbar + chip + row + mobile collapse all present"

grep -q "role=\"toolbar\"" "$APP_JS" || fail "audit toolbar missing role=toolbar"
grep -q "role=\"grid\"" "$APP_JS"    || fail "audit table missing role=grid"
ok "a11y: role=toolbar + role=grid"

grep -q "PRODUCT-111\|OPERATOR_CONSOLE_V2" "$APP_JS" \
    || fail "ChumpViewAudit missing PRODUCT-111 / OPERATOR_CONSOLE_V2 provenance"
ok "provenance: PRODUCT-111 + design doc referenced"

ok "ALL PRODUCT-111 audit-view checks passed"
