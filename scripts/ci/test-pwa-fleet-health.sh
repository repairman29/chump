#!/usr/bin/env bash
# scripts/ci/test-pwa-fleet-health.sh — INFRA-1203
#
# Structural test for the <chump-view-fleet-health> 4-panel operator-vitals view.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
APP_JS="$REPO_ROOT/web/v2/app.js"
INDEX_HTML="$REPO_ROOT/web/v2/index.html"

ok()   { printf '\033[0;32mPASS\033[0m %s\n' "$*"; }
fail() { printf '\033[0;31mFAIL\033[0m %s\n' "$*"; exit 1; }

[[ -f "$APP_JS" ]]     || fail "missing $APP_JS"
[[ -f "$INDEX_HTML" ]] || fail "missing $INDEX_HTML"

grep -q "class ChumpViewFleetHealth" "$APP_JS"      || fail "missing ChumpViewFleetHealth class"
grep -q "customElements.define('chump-view-fleet-health'" "$APP_JS" || fail "view not registered"
ok "ChumpViewFleetHealth defined + registered"

grep -q "health:.*chump-view-fleet-health" "$APP_JS" || fail "health not in VIEWS router"
ok "health registered in VIEWS map"

grep -q "id: 'health'" "$APP_JS" || fail "health missing from AMBIENT cadence subtabs"
ok "AMBIENT cadence includes health sub-tab"

# 4 panels structural
for cls in fh-pillars fh-kpis fh-slos fh-budget; do
    grep -q "$cls" "$APP_JS" || fail "missing .$cls panel"
done
ok "4 panels: pillars / KPIs / SLOs / GraphQL budget"

# Pillar quadrant — 4 pillars iterated as template list
grep -q "'effective','credible','resilient','zero-waste'" "$APP_JS" \
    || fail "pillar list missing effective/credible/resilient/zero-waste"
grep -q "fh-pillar-cell fh-pillar-\${p}" "$APP_JS" \
    || fail "pillar cell template missing per-pillar class binding"
grep -q "id=\"fh-grade-\${p}\"" "$APP_JS" \
    || fail "pillar grade element missing per-pillar id"
ok "4 pillar cells iterated: effective / credible / resilient / zero-waste"

# Data sources
grep -q "fetch('/api/stack-status')"      "$APP_JS" || fail "missing /api/stack-status fetch"
grep -q "fetch('/api/dashboard')"          "$APP_JS" || fail "missing /api/dashboard fetch"
grep -q "fetch('/api/telemetry/cost')"     "$APP_JS" || fail "missing /api/telemetry/cost fetch"
grep -q "fetch('/api/fleet-status')"       "$APP_JS" || fail "missing /api/fleet-status fetch"
ok "data composition: 4 existing endpoints (no new backend required)"

# KPI strip with 4 KPIs
for kpi in fh-kpi-fleet fh-kpi-cost fh-kpi-heartbeat fh-kpi-ships; do
    grep -q "id=\"$kpi\"" "$APP_JS" || fail "missing KPI: $kpi"
done
ok "4 KPIs: fleet / cost / last-heartbeat / ships"

# Cost-threshold integration
grep -q "chumpPrefs?.get('cost.thresholds'" "$APP_JS" \
    || fail "cost KPI doesn't read chumpPrefs cost.thresholds (PRODUCT-113 integration)"
ok "cost KPI integrates with PRODUCT-113 thresholds via chumpPrefs"

# SLO list reads fleet_status + fleet_status_reason (INFRA-1206)
grep -q "fleet_status\|fleet_status_reason" "$APP_JS" \
    || fail "SLO list doesn't consume INFRA-1206 fleet_status + reason"
ok "SLO list: INFRA-1206 fleet_status + reason wired"

# Telemetry
grep -q "fleet_health_view_session" "$APP_JS" \
    || fail "missing kind=fleet_health_view_session telemetry"
grep -B5 "fleet_health_view_session" "$APP_JS" | grep -q "sendBeacon" \
    || fail "telemetry should use sendBeacon"
ok "telemetry: fleet_health_view_session via sendBeacon"

# CSS for all 4 panels + mobile
grep -q ".fh-pillar-quadrant"     "$INDEX_HTML" || fail "missing pillar quadrant CSS"
grep -q ".fh-kpis-grid"           "$INDEX_HTML" || fail "missing KPI grid CSS"
grep -q ".fh-slo-list"            "$INDEX_HTML" || fail "missing SLO list CSS"
grep -q ".fh-budget-bar"          "$INDEX_HTML" || fail "missing GraphQL budget bar CSS"
grep -A50 "chump-view-fleet-health" "$INDEX_HTML" | grep -q "@media.*max-width: 640px" \
    || fail "missing mobile media query"
ok "CSS: 4 panels + mobile collapse all styled"

# Auto-refresh
grep -q "setInterval.*load\|load.*30_000\|30_000.*load" "$APP_JS" \
    || fail "missing 30s poll timer"
ok "auto-refresh: 30s poll"

# Provenance
grep -q "INFRA-1203" "$APP_JS" \
    || fail "missing INFRA-1203 provenance"
ok "provenance: INFRA-1203 referenced"

ok "ALL INFRA-1203 fleet-health checks passed"
