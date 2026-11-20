#!/usr/bin/env bash
# scripts/ci/test-pwa-roadmap-view.sh — INFRA-1207
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
APP_JS="$REPO_ROOT/web/v2/app.js"
INDEX_HTML="$REPO_ROOT/web/v2/index.html"
ok()   { printf '\033[0;32mPASS\033[0m %s\n' "$*"; }
fail() { printf '\033[0;31mFAIL\033[0m %s\n' "$*"; exit 1; }

[[ -f "$APP_JS" ]] || fail "missing $APP_JS"

grep -q "class ChumpViewRoadmap" "$APP_JS"          || fail "missing ChumpViewRoadmap class"
grep -q "customElements.define('chump-view-roadmap'" "$APP_JS" || fail "view not registered"
ok "ChumpViewRoadmap defined + registered"

grep -q "roadmap:.*chump-view-roadmap" "$APP_JS"    || fail "roadmap not in VIEWS router"
ok "roadmap registered in VIEWS map"

grep -q "id: 'roadmap'" "$APP_JS"                   || fail "roadmap missing from LIBRARY cadence"
ok "LIBRARY cadence includes roadmap sub-tab"

grep -q "fetch('/api/roadmap')"                     "$APP_JS" || fail "missing /api/roadmap fetch"
grep -q "fetch('/docs/ROADMAP.md')"                 "$APP_JS" || fail "missing markdown fallback fetch"
ok "data sources: /api/roadmap with /docs/ROADMAP.md fallback"

grep -q "#parseMarkdown"                            "$APP_JS" || fail "missing markdown parser"
ok "markdown parser: parses ## Milestone headings + status/gaps fields"

grep -q "roadmap-milestone-active"   "$APP_JS" || fail "missing active milestone class"
grep -q "roadmap-milestone-next"     "$APP_JS" || fail "missing next milestone class"
grep -q "roadmap-milestone-done"     "$APP_JS" || fail "missing done milestone class"
grep -q "roadmap-milestone-blocked"  "$APP_JS" || fail "missing blocked milestone class"
ok "4 status variants: active / next / done / blocked"

grep -q "roadmap-gap-chip" "$APP_JS" || fail "missing gap chip rendering"
grep -q "/v2/?view=agent" "$APP_JS"   || fail "gap chip doesn't link to queue view"
ok "gap chips: rendered + cross-link to /v2/?view=agent"

grep -q "roadmap-current-only" "$APP_JS" || fail "missing 'current only' filter toggle"
ok "filter: 'current only' toggle"

grep -q "roadmap-blockers" "$APP_JS" || fail "missing blockers callout"
ok "blockers callout: red banner per milestone"

grep -q "roadmap_view_session" "$APP_JS" \
    || fail "missing kind=roadmap_view_session telemetry"
grep -B5 "roadmap_view_session" "$APP_JS" | grep -q "sendBeacon" \
    || fail "telemetry should use sendBeacon"
ok "telemetry: roadmap_view_session via sendBeacon"

grep -q "chump-view-roadmap .roadmap-milestone" "$INDEX_HTML" || fail "missing milestone CSS"
grep -q "chump-view-roadmap .roadmap-gap-chip"  "$INDEX_HTML" || fail "missing gap-chip CSS"
grep -A60 "chump-view-roadmap" "$INDEX_HTML" | grep -q "@media.*max-width: 640px" \
    || fail "missing mobile media query"
ok "CSS: milestone variants + gap chips + mobile collapse all styled"

grep -q "INFRA-1207" "$APP_JS" \
    || fail "missing INFRA-1207 provenance"
ok "provenance: INFRA-1207 referenced"

ok "ALL INFRA-1207 roadmap-view checks passed"
