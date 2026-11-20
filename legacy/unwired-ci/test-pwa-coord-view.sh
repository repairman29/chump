#!/usr/bin/env bash
# scripts/ci/test-pwa-coord-view.sh — INFRA-1204
#
# Structural test for the <chump-view-coord> a2a coordination panel.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
APP_JS="$REPO_ROOT/web/v2/app.js"
INDEX_HTML="$REPO_ROOT/web/v2/index.html"

ok()   { printf '\033[0;32mPASS\033[0m %s\n' "$*"; }
fail() { printf '\033[0;31mFAIL\033[0m %s\n' "$*"; exit 1; }

[[ -f "$APP_JS" ]]     || fail "missing $APP_JS"
[[ -f "$INDEX_HTML" ]] || fail "missing $INDEX_HTML"

grep -q "class ChumpViewCoord" "$APP_JS"            || fail "missing ChumpViewCoord class"
grep -q "customElements.define('chump-view-coord'" "$APP_JS" || fail "chump-view-coord not registered"
ok "ChumpViewCoord defined + registered"

grep -q "coord:.*chump-view-coord" "$APP_JS"        || fail "coord not in VIEWS router map"
ok "coord registered in VIEWS map"

grep -q "id: 'coord'" "$APP_JS"                     || fail "coord missing from AMBIENT cadence subtabs"
ok "AMBIENT cadence includes coord sub-tab"

# 3-panel structure
for cls in coord-inbox coord-intents coord-nudges; do
    grep -q "$cls" "$APP_JS" || fail "missing .$cls panel"
done
ok "3 panels: inbox + intents + nudges"

# Data sources
grep -q "fetch(\`/api/inbox/" "$APP_JS"             || fail "missing /api/inbox/{session} fetch"
grep -q "kind=intent_announced" "$APP_JS"           || fail "missing kind=intent_announced filter on ambient/recent"
grep -q "kind=pr_nudge_emitted" "$APP_JS"           || fail "missing kind=pr_nudge_emitted filter on ambient/recent"
ok "data sources: inbox + intents + nudges all wired"

# Session picker + chumpPrefs
grep -q "coord-session-select" "$APP_JS"            || fail "missing session-picker dropdown"
grep -q "chumpPrefs?.set('coord.session'" "$APP_JS" || fail "selected session not persisted"
grep -q "chumpPrefs?.get('coord.session'" "$APP_JS" || fail "selected session not restored on mount"
ok "session picker: persistence via chumpPrefs coord.session"

# 5 nudge classes
for k in dirty blocked-ci orphan-disarmed base-modified clean-not-merged; do
    grep -q "coord-row-class-$k" "$INDEX_HTML" || fail "missing nudge-class color: $k"
done
ok "5 nudge-class color variants in CSS"

# Auto-refresh
grep -q "setInterval.*loadAll\|loadAll.*20\|20_000.*loadAll" "$APP_JS" \
    || fail "no 20s poll timer wired"
ok "auto-refresh: poll every 20s"

# Telemetry
grep -q "coord_view_session" "$APP_JS" \
    || fail "missing telemetry kind=coord_view_session"
grep -B5 "coord_view_session" "$APP_JS" | grep -q "sendBeacon" \
    || fail "telemetry should use sendBeacon"
ok "telemetry: coord_view_session via sendBeacon"

# CSS
grep -q "chump-view-coord .coord-panel" "$INDEX_HTML" || fail "missing .coord-panel CSS"
grep -q "chump-view-coord .coord-row"   "$INDEX_HTML" || fail "missing .coord-row CSS"
grep -A60 "chump-view-coord" "$INDEX_HTML" | grep -q "@media.*max-width: 640px" \
    || fail "missing mobile media query"
ok "CSS: panels + rows + mobile collapse all styled"

# A11y
grep -q "aria-live=\"polite\"" "$APP_JS" || fail "lists missing aria-live"
ok "a11y: aria-live=polite on all 3 list panels"

# Provenance
grep -q "INFRA-1204" "$APP_JS" \
    || fail "missing INFRA-1204 provenance"
ok "provenance: INFRA-1204 referenced"

ok "ALL INFRA-1204 coord-view checks passed"
