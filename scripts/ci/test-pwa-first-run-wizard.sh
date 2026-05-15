#!/usr/bin/env bash
# scripts/ci/test-pwa-first-run-wizard.sh — PRODUCT-108
#
# Structural test for the <chump-first-run-wizard> Web Component.
# Verifies the operator first-run experience scaffold:
#   - 5-step golden-path: model / repo / brain / autopilot / first_gap
#   - Each step's detect() probes the right endpoint
#   - Skip + Dismiss flows
#   - chumpPrefs persistence (firstrun.step.<id> + firstrun.dismissed)
#   - Telemetry: kind=firstrun_step_complete with step + action
#   - Self-hide when all 5 done OR dismissed
#   - CSS for shell + step rows + mobile layout
#   - A11y: role=region + aria-current=step
#   - Provenance trail to PRODUCT-108 + design doc

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
APP_JS="$REPO_ROOT/web/v2/app.js"
INDEX_HTML="$REPO_ROOT/web/v2/index.html"

ok()   { printf '\033[0;32mPASS\033[0m %s\n' "$*"; }
fail() { printf '\033[0;31mFAIL\033[0m %s\n' "$*"; exit 1; }

[[ -f "$APP_JS" ]]     || fail "missing $APP_JS"
[[ -f "$INDEX_HTML" ]] || fail "missing $INDEX_HTML"

# ── Test 1: component class + registration ─────────────────────────────────
grep -q "class ChumpFirstRunWizard" "$APP_JS" \
    || fail "app.js missing ChumpFirstRunWizard class"
grep -q "customElements.define('chump-first-run-wizard'" "$APP_JS" \
    || fail "app.js missing customElements.define for chump-first-run-wizard"
ok "ChumpFirstRunWizard class defined + registered"

# ── Test 2: mounted in shell ────────────────────────────────────────────────
grep -q "<chump-first-run-wizard>" "$INDEX_HTML" \
    || fail "index.html doesn't mount <chump-first-run-wizard>"
ok "wizard mounted in app shell"

# ── Test 3: 5-step golden path with canonical IDs ──────────────────────────
grep -q "const FIRSTRUN_STEPS" "$APP_JS" \
    || fail "FIRSTRUN_STEPS list missing"
for step in model repo brain autopilot first_gap; do
    grep -q "id: '$step'" "$APP_JS" || fail "FIRSTRUN_STEPS missing step: $step"
done
ok "5 steps present: model / repo / brain / autopilot / first_gap"

# ── Test 4: each step's detect() probes the right endpoint ─────────────────
grep -q "fetch('/api/stack-status')"      "$APP_JS" || fail "model step doesn't probe /api/stack-status"
grep -q "fetch('/api/repo/context')"      "$APP_JS" || fail "repo step doesn't probe /api/repo/context"
grep -q "fetch('/api/brain/graph/stats')" "$APP_JS" || fail "brain step doesn't probe /api/brain/graph/stats"
grep -q "fetch('/api/autopilot/status')"  "$APP_JS" || fail "autopilot step doesn't probe /api/autopilot/status"
grep -q "fetch('/api/gap-queue?status=claimed')" "$APP_JS" || fail "first_gap step doesn't probe /api/gap-queue?status=claimed"
ok "5 detect() probes wire to the 5 canonical endpoints"

# ── Test 5: chumpPrefs persistence ─────────────────────────────────────────
grep -q "chumpPrefs?.set(\`firstrun.step" "$APP_JS" \
    || fail "step status not persisted via chumpPrefs firstrun.step.<id>"
grep -q "chumpPrefs?.set('firstrun.dismissed'" "$APP_JS" \
    || fail "dismiss state not persisted via chumpPrefs firstrun.dismissed"
grep -q "chumpPrefs?.get('firstrun.dismissed'" "$APP_JS" \
    || fail "dismiss state not READ from chumpPrefs at mount (would re-show after dismiss)"
ok "chumpPrefs: firstrun.step.<id> + firstrun.dismissed both read+written"

# ── Test 6: Skip + Dismiss buttons wired ───────────────────────────────────
grep -q "#skipStep" "$APP_JS"  || fail "missing #skipStep method"
grep -q "#dismiss"  "$APP_JS"  || fail "missing #dismiss method"
grep -q "data-step-skip" "$APP_JS" || fail "Skip buttons missing data-step-skip attribute"
ok "Skip + Dismiss flows wired"

# ── Test 7: telemetry — kind=firstrun_step_complete via sendBeacon ────────
grep -q "firstrun_step_complete" "$APP_JS" \
    || fail "missing kind=firstrun_step_complete telemetry"
grep -B5 "firstrun_step_complete" "$APP_JS" | grep -q "sendBeacon" \
    || fail "telemetry should use sendBeacon (non-blocking)"
grep -A8 "firstrun_step_complete" "$APP_JS" | grep -q "step.*action\|action.*step" \
    || fail "firstrun_step_complete event missing step + action fields"
ok "telemetry: firstrun_step_complete {step, action, ts} via sendBeacon"

# ── Test 8: self-hide when all done OR dismissed ───────────────────────────
grep -q "#isAllDone" "$APP_JS" \
    || fail "missing #isAllDone check"
grep -A4 "#isAllDone" "$APP_JS" | grep -q "every\|status !== 'pending'" \
    || fail "#isAllDone logic doesn't check all steps are non-pending"
ok "self-hide: #isAllDone() gates rendering"

# ── Test 9: poll every 5s for auto-detection ───────────────────────────────
grep -q "setInterval.*detectAll\|detectAll.*5000\|5000.*detectAll" "$APP_JS" \
    || fail "no 5s polling timer wired for detectAll"
ok "polling: detectAll runs every 5s"

# ── Test 10: stepAction wires chump:navigate for Queue / Settings ──────────
grep -q "chump:navigate" "$APP_JS" \
    || fail "stepAction missing chump:navigate dispatch (Queue / Settings buttons)"
grep -q "open-queue\|open-config\|start-autopilot" "$APP_JS" \
    || fail "missing canonical action kinds (open-queue/open-config/start-autopilot)"
ok "step actions: chump:navigate + start-autopilot wired"

# ── Test 11: CSS for shell + 5 step variants + mobile ──────────────────────
grep -q "chump-first-run-wizard .frw-shell" "$INDEX_HTML" || fail "missing .frw-shell CSS"
for variant in done skipped current pending; do
    grep -q "frw-step-$variant" "$INDEX_HTML" || fail "missing .frw-step-$variant CSS"
done
grep -A80 "chump-first-run-wizard" "$INDEX_HTML" | grep -q "@media.*max-width: 640px" \
    || fail "missing mobile media query"
ok "CSS: shell + 4 step status variants + mobile media query"

# ── Test 12: a11y — role=region + aria-current=step ───────────────────────
grep -q "role=\"region\"" "$APP_JS" \
    || fail "wizard shell missing role=region"
grep -q "aria-current" "$APP_JS" \
    || fail "current step missing aria-current=step indicator"
ok "a11y: role=region + aria-current on active step"

# ── Test 13: provenance — PRODUCT-108 + OPERATOR_CONSOLE_V2 ───────────────
grep -q "PRODUCT-108\|OPERATOR_CONSOLE_V2" "$APP_JS" \
    || fail "ChumpFirstRunWizard missing PRODUCT-108 / OPERATOR_CONSOLE_V2 provenance"
ok "code references PRODUCT-108 + design doc"

ok "ALL PRODUCT-108 first-run-wizard checks passed"
