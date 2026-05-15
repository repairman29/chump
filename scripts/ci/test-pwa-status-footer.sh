#!/usr/bin/env bash
# scripts/ci/test-pwa-status-footer.sh — PRODUCT-107
#
# Structural test for the <chump-status-footer> Web Component.
# Verifies the persistent operator HUD wiring:
#   - Component defined + mounted in shell
#   - 6 slots: model / cost / airgap / pillars / fleet / gh
#   - Each slot has data-target = "<cadence>:<view>" for click-drill
#   - Independent pollers (3 fetchers wired)
#   - Stale-fallback class .sf-stale on poll failure
#   - Threshold-based color classes (.sf-warn / .sf-red) reading
#     chumpPrefs cost.thresholds (INFRA-1280 integration)
#   - Telemetry: kind=footer_slot_drilled via sendBeacon
#   - CSS for shell + slot variants + mobile wrap
#   - A11y: role=contentinfo, aria-label on shell + each slot

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
APP_JS="$REPO_ROOT/web/v2/app.js"
INDEX_HTML="$REPO_ROOT/web/v2/index.html"

ok()   { printf '\033[0;32mPASS\033[0m %s\n' "$*"; }
fail() { printf '\033[0;31mFAIL\033[0m %s\n' "$*"; exit 1; }

[[ -f "$APP_JS" ]]     || fail "missing $APP_JS"
[[ -f "$INDEX_HTML" ]] || fail "missing $INDEX_HTML"

# ── Test 1: ChumpStatusFooter class + customElements.define ─────────────────
grep -q "class ChumpStatusFooter" "$APP_JS" \
    || fail "app.js missing ChumpStatusFooter class"
grep -q "customElements.define('chump-status-footer'" "$APP_JS" \
    || fail "app.js missing customElements.define for chump-status-footer"
ok "ChumpStatusFooter class defined + registered"

# ── Test 2: mounted in index.html app shell ─────────────────────────────────
grep -q "<chump-status-footer>" "$INDEX_HTML" \
    || fail "index.html doesn't mount <chump-status-footer>"
ok "footer mounted in app shell"

# ── Test 3: 6 slots present with canonical data-slot ids ───────────────────
for slot in model cost airgap pillars fleet gh; do
    grep -q "data-slot=\"$slot\"" "$APP_JS" \
        || fail "footer missing data-slot=\"$slot\""
done
ok "all 6 slots present (model/cost/airgap/pillars/fleet/gh)"

# ── Test 4: each slot has data-target for click-drill ──────────────────────
grep -q "data-target=\"config:models\""        "$APP_JS" || fail "model slot missing data-target=config:models"
grep -q "data-target=\"library:judgment\""     "$APP_JS" || fail "cost/pillars/gh slots missing data-target=library:judgment"
grep -q "data-target=\"config:settings\""      "$APP_JS" || fail "airgap slot missing data-target=config:settings"
grep -q "data-target=\"ambient:agents\""       "$APP_JS" || fail "fleet slot missing data-target=ambient:agents"
ok "click-drill: every slot has data-target cadence:view"

# ── Test 5: independent pollers wired (3 fetchers) ─────────────────────────
grep -q "#pollStackStatus" "$APP_JS" || fail "missing #pollStackStatus poller"
grep -q "#pollCost"        "$APP_JS" || fail "missing #pollCost poller"
grep -q "#pollFleet"       "$APP_JS" || fail "missing #pollFleet poller"
grep -q "fetch('/api/stack-status')"   "$APP_JS" || fail "missing /api/stack-status fetch"
grep -q "fetch('/api/telemetry/cost')" "$APP_JS" || fail "missing /api/telemetry/cost fetch"
grep -q "fetch('/api/fleet-status')"   "$APP_JS" || fail "missing /api/fleet-status fetch"
ok "3 independent pollers: stack-status + telemetry/cost + fleet-status"

# ── Test 6: stale fallback class .sf-stale ─────────────────────────────────
grep -q "sf-stale" "$APP_JS"  || fail "no .sf-stale class for poll-failure rendering"
grep -q "sf-stale" "$INDEX_HTML" || fail "index.html missing .sf-stale opacity rule"
ok "stale-fallback: .sf-stale class wired on poll failure"

# ── Test 7: threshold color bands (.sf-warn / .sf-red) ─────────────────────
grep -q "sf-warn" "$APP_JS" || fail "no .sf-warn threshold class"
grep -q "sf-red"  "$APP_JS" || fail "no .sf-red threshold class"
grep -q "cost.thresholds" "$APP_JS" \
    || fail "cost slot doesn't read chumpPrefs cost.thresholds (INFRA-1280 integration)"
ok "threshold bands: warn/red reading chumpPrefs cost.thresholds"

# ── Test 8: telemetry kind=footer_slot_drilled via sendBeacon ──────────────
grep -q "footer_slot_drilled" "$APP_JS" \
    || fail "missing kind=footer_slot_drilled telemetry"
grep -B5 "footer_slot_drilled" "$APP_JS" | grep -q "sendBeacon" \
    || fail "footer_slot_drilled telemetry should use sendBeacon"
ok "telemetry: footer_slot_drilled via sendBeacon"

# ── Test 9: click dispatches chump:navigate (canvas integration) ───────────
grep -q "chump:navigate" "$APP_JS" \
    || fail "footer click handler doesn't dispatch chump:navigate"
ok "click handler: dispatches chump:navigate for cadence-canvas integration"

# ── Test 10: CSS — shell + slot + dot + value + mobile wrap ───────────────
grep -q "chump-status-footer .sf-shell"  "$INDEX_HTML" || fail "missing .sf-shell CSS"
grep -q "chump-status-footer .sf-slot"   "$INDEX_HTML" || fail "missing .sf-slot CSS"
grep -q "chump-status-footer .sf-value"  "$INDEX_HTML" || fail "missing .sf-value CSS"
grep -A60 "chump-status-footer" "$INDEX_HTML" | grep -q "@media.*max-width: 640px" \
    || fail "missing mobile media query for footer"
ok "CSS: shell + slot + value + mobile wrap all styled"

# ── Test 11: a11y — role=contentinfo + aria-label on each slot ────────────
grep -q "role=\"contentinfo\"" "$APP_JS" \
    || fail "footer shell missing role=contentinfo"
# Each slot has aria-label set on its <button>. Multi-line aware: grep -A1 looks
# at the slot line + the next line where aria-label lives in our template.
SLOTS_NEED_ARIA="$(grep -B0 -A1 -E "data-slot=\"[a-z]+\"" "$APP_JS" \
    | awk 'BEGIN{RS="--\n"} {if (!index($0,"aria-label") && index($0,"data-slot=")) print $0}')"
[[ -z "$SLOTS_NEED_ARIA" ]] || fail "slots missing aria-label:
$SLOTS_NEED_ARIA"
ok "a11y: role=contentinfo + aria-label on every slot button"

# ── Test 12: provenance — PRODUCT-107 / OPERATOR_CONSOLE_V2.md referenced ──
grep -q "PRODUCT-107\|OPERATOR_CONSOLE_V2" "$APP_JS" \
    || fail "ChumpStatusFooter missing PRODUCT-107 / OPERATOR_CONSOLE_V2 provenance"
ok "code references PRODUCT-107 + design doc"

ok "ALL PRODUCT-107 status-footer checks passed"
