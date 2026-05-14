#!/usr/bin/env bash
# scripts/ci/test-pwa-canvas-cadence.sh — PRODUCT-106
#
# Structural test for the four-cadence operator console nav per
# docs/design/OPERATOR_CONSOLE_V2.md. Verifies:
#   - CHUMP_CADENCES + CHUMP_VIEW_TO_CADENCE are defined
#   - 4 cadences: now / ambient / library / config
#   - Every legacy data-view name maps to exactly one cadence
#   - chump:navigate event still dispatched (router back-compat)
#   - Keyboard shortcuts (n/a/l/c) wired
#   - chumpPrefs persistence (chump.last_cadence)
#   - URL ?cadence + ?view reflection
#   - Telemetry: kind=cadence_view_active emitted on switch
#   - Mobile media query collapse to horizontal strip
#
# End-to-end DOM cadence-switching is exercised by the e2e-pwa CI job;
# this structural test catches regressions cheaply.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
APP_JS="$REPO_ROOT/web/v2/app.js"
INDEX_HTML="$REPO_ROOT/web/v2/index.html"
DESIGN_DOC="$REPO_ROOT/docs/design/OPERATOR_CONSOLE_V2.md"

ok()   { printf '\033[0;32mPASS\033[0m %s\n' "$*"; }
fail() { printf '\033[0;31mFAIL\033[0m %s\n' "$*"; exit 1; }

[[ -f "$APP_JS" ]]     || fail "missing $APP_JS"
[[ -f "$INDEX_HTML" ]] || fail "missing $INDEX_HTML"

# ── Test 1: CHUMP_CADENCES exists + has 4 entries ───────────────────────────
grep -q "const CHUMP_CADENCES = \[" "$APP_JS" \
    || fail "app.js missing CHUMP_CADENCES declaration"
for cad in now ambient library config; do
    grep -q "id: '$cad'" "$APP_JS" \
        || fail "CHUMP_CADENCES missing cadence: $cad"
done
ok "CHUMP_CADENCES: 4 cadences (now/ambient/library/config) defined"

# ── Test 2: CHUMP_VIEW_TO_CADENCE map exists ───────────────────────────────
grep -q "const CHUMP_VIEW_TO_CADENCE" "$APP_JS" \
    || fail "app.js missing CHUMP_VIEW_TO_CADENCE legacy-view lookup"
ok "CHUMP_VIEW_TO_CADENCE: legacy-view → cadence map present (back-compat)"

# ── Test 3: chump:navigate still dispatched on view switch ─────────────────
grep -q "chump:navigate" "$APP_JS" \
    || fail "router event chump:navigate gone — back-compat broken"
ok "router back-compat: chump:navigate event still dispatched"

# ── Test 4: keyboard shortcuts wired (n/a/l/c) ──────────────────────────────
grep -q "shortcut: 'n'" "$APP_JS" || fail "NOW cadence missing 'n' shortcut"
grep -q "shortcut: 'a'" "$APP_JS" || fail "AMBIENT cadence missing 'a' shortcut"
grep -q "shortcut: 'l'" "$APP_JS" || fail "LIBRARY cadence missing 'l' shortcut"
grep -q "shortcut: 'c'" "$APP_JS" || fail "CONFIG cadence missing 'c' shortcut"
grep -q "addEventListener('keydown'" "$APP_JS" \
    || fail "no keydown listener wired for shortcuts"
ok "keyboard shortcuts: n/a/l/c all wired"

# ── Test 5: chumpPrefs persistence wired (last_cadence) ────────────────────
grep -q "chumpPrefs?.set('last_cadence'" "$APP_JS" \
    || fail "last_cadence not persisted via chumpPrefs"
grep -q "chumpPrefs?.get('last_cadence'" "$APP_JS" \
    || fail "last_cadence not restored from chumpPrefs"
ok "persistence: last_cadence via INFRA-1280 chumpPrefs"

# ── Test 6: URL ?cadence + ?view reflection ─────────────────────────────────
grep -q "url.searchParams.set('cadence'" "$APP_JS" \
    || fail "?cadence not reflected to URL"
grep -q "url.searchParams.set('view'" "$APP_JS" \
    || fail "?view not reflected to URL (deep-link breakage)"
grep -q "history.replaceState" "$APP_JS" \
    || fail "URL updates should use replaceState (not pushState) per AC"
ok "URL reflection: ?cadence + ?view both replaceState'd"

# ── Test 7: telemetry emitted on cadence switch ────────────────────────────
grep -q "cadence_view_active" "$APP_JS" \
    || fail "kind=cadence_view_active telemetry not emitted"
grep -A5 "cadence_view_active" "$APP_JS" | grep -q "dwell_s" \
    || fail "cadence_view_active event missing dwell_s field"
grep -B5 "cadence_view_active" "$APP_JS" | grep -q "sendBeacon" \
    || fail "telemetry should use sendBeacon (non-blocking)"
ok "telemetry: cadence_view_active {cadence, dwell_s} via sendBeacon"

# ── Test 8: every legacy view-id maps to a cadence (no orphans) ────────────
python3 - <<EOF
import re
src = open("$APP_JS").read()
# Find the subtabs list per cadence.
cadence_views = set(re.findall(r"id: '([a-z_-]+)'", src))
# These are the historical view-ids that were peers in the old nav.
legacy = {'chat','agents','results','agent','tasks','decisions','judgment','ambient','notifications','memory','models','settings'}
unmapped = legacy - cadence_views
if unmapped:
    raise SystemExit(f"FAIL: legacy views with no cadence home: {sorted(unmapped)}")
print(f"  legacy views all mapped: {sorted(legacy)}")
EOF
[[ $? -eq 0 ]] || fail "legacy-view → cadence mapping incomplete"
ok "legacy back-compat: every previous data-view name maps to a cadence"

# ── Test 9: CSS for nav-cadences + nav-subtabs + mobile collapse ───────────
grep -q "chump-nav .nav-cadence" "$INDEX_HTML" \
    || fail "index.html missing .nav-cadence CSS"
grep -q "chump-nav .nav-subtabs" "$INDEX_HTML" \
    || fail "index.html missing .nav-subtabs CSS"
grep -q "@media (max-width: 640px)" "$INDEX_HTML" \
    || fail "index.html missing mobile media query for nav collapse"
ok "CSS: cadence rail + sub-tab strip + mobile collapse all styled"

# ── Test 10: design doc reference in code ──────────────────────────────────
grep -q "OPERATOR_CONSOLE_V2.md\|PRODUCT-106" "$APP_JS" \
    || fail "app.js doesn't reference the design doc / gap (provenance trail)"
ok "code references docs/design/OPERATOR_CONSOLE_V2.md (provenance trail)"

# ── Test 11: a11y — tablist roles + aria-current ────────────────────────────
grep -q "role=\"tablist\"" "$APP_JS" \
    || fail "nav-cadences missing role=tablist"
grep -q "role=\"tab\"" "$APP_JS" \
    || fail "cadence buttons missing role=tab"
grep -qE "aria-current=\"page\"|setAttribute\('aria-current', 'page'\)" "$APP_JS" \
    || fail "active cadence missing aria-current"
ok "a11y: tablist roles + aria-current on active cadence"

ok "ALL PRODUCT-106 canvas-cadence checks passed"
