#!/usr/bin/env bash
# scripts/ci/test-pwa-network-audit.sh — PRODUCT-112
#
# Structural test for the <chump-view-network-audit> air-gap trust page.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
APP_JS="$REPO_ROOT/web/v2/app.js"
INDEX_HTML="$REPO_ROOT/web/v2/index.html"

ok()   { printf '\033[0;32mPASS\033[0m %s\n' "$*"; }
fail() { printf '\033[0;31mFAIL\033[0m %s\n' "$*"; exit 1; }

[[ -f "$APP_JS" ]]     || fail "missing $APP_JS"
[[ -f "$INDEX_HTML" ]] || fail "missing $INDEX_HTML"

grep -q "class ChumpViewNetworkAudit" "$APP_JS" \
    || fail "missing ChumpViewNetworkAudit class"
grep -q "customElements.define('chump-view-network-audit'" "$APP_JS" \
    || fail "chump-view-network-audit not registered"
ok "ChumpViewNetworkAudit defined + registered"

grep -q "network:.*chump-view-network-audit" "$APP_JS" \
    || fail "network not in VIEWS router map"
ok "network registered in VIEWS router map"

grep -q "id: 'network'" "$APP_JS" \
    || fail "network missing from CONFIG cadence subtabs"
ok "CONFIG cadence includes network sub-tab"

grep -q "sf-airgap.*data-target=\"config:network\"" "$APP_JS" \
    || fail "footer air-gap slot doesn't drill to config:network"
ok "footer air-gap slot drills to config:network"

grep -q "fetch('/api/stack-status')" "$APP_JS" \
    || fail "missing /api/stack-status fetch (for air_gap_mode)"
grep -q "fetch(\`/api/ambient/recent\?" "$APP_JS" \
    || fail "missing /api/ambient/recent fetch with kind filter"
grep -q "kind=github_api_call,outbound_http_call\|github_api_call.*outbound_http_call" "$APP_JS" \
    || fail "ambient/recent fetch missing canonical kind filter"
ok "data sources: /api/stack-status + /api/ambient/recent filtered to outbound kinds"

# Time-window chips
for win in "'10m'" "'1h'" "'24h'" "'all'"; do
    grep -q "$win" "$APP_JS" || fail "missing time-window chip: $win"
done
ok "time-window chips: 10m / 1h / 24h / all"

# Violation banner triggered when air_gap_mode + non-github rows
grep -q "netaudit-banner-violation" "$APP_JS" \
    || fail "missing violation banner class"
grep -q "netaudit-banner-ok" "$APP_JS" \
    || fail "missing ok banner class (celebrates the win)"
grep -q "air-gap claim" "$APP_JS" \
    || fail "violation/ok messaging should mention 'air-gap claim'"
ok "banner states: violation (red) + ok (green) + info wired"

# GitHub exception footnote
grep -q "github\.com.*exception\|documented exceptions" "$APP_JS" \
    || fail "github.com exception footnote missing"
grep -q "netaudit-pill-ok" "$APP_JS" \
    || fail "github rows missing 'exception' pill"
ok "GitHub exception: footnote + per-row pill present"

# Empty state celebrates the offline win (archetype 1)
grep -q "celebrate the offline win\|Air-gap claim holds" "$APP_JS" \
    || fail "empty state should celebrate the offline win for archetype 1"
ok "empty state: celebrates the offline win"

# Export
grep -q ".netaudit-export\|application/x-ndjson\|chump-network-audit-.*\.jsonl" "$APP_JS" \
    || fail "missing JSONL export"
ok "export: visible rows → JSONL download"

# Telemetry
grep -q "network_audit_viewed\|network_audit_exported" "$APP_JS" \
    || fail "missing telemetry events"
grep -B5 "network_audit_viewed\|network_audit_exported" "$APP_JS" | grep -q "sendBeacon" \
    || fail "telemetry should use sendBeacon"
ok "telemetry: network_audit_viewed + network_audit_exported via sendBeacon"

# CSS
grep -q "chump-view-network-audit .netaudit-banner-violation" "$INDEX_HTML" \
    || fail "missing violation-banner CSS"
grep -q "chump-view-network-audit .netaudit-banner-ok" "$INDEX_HTML" \
    || fail "missing ok-banner CSS"
grep -q "chump-view-network-audit .netaudit-row-nongithub" "$INDEX_HTML" \
    || fail "missing non-github row highlight CSS"
grep -A60 "chump-view-network-audit" "$INDEX_HTML" | grep -q "@media.*max-width: 640px" \
    || fail "missing mobile media query"
ok "CSS: banners + non-github highlight + mobile collapse all styled"

# A11y
grep -q "role=\"toolbar\"" "$APP_JS" || fail "toolbar missing role"
grep -q "aria-live=\"polite\"" "$APP_JS" || fail "list missing aria-live"
ok "a11y: role=toolbar + aria-live=polite"

# Provenance
grep -q "PRODUCT-112" "$APP_JS" \
    || fail "missing PRODUCT-112 provenance"
ok "provenance: PRODUCT-112 referenced"

ok "ALL PRODUCT-112 network-audit checks passed"
