#!/usr/bin/env bash
# scripts/ci/test-pwa-cost-ceiling.sh — PRODUCT-113
#
# Structural test for the cost-ceiling + kill-switch surface.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
APP_JS="$REPO_ROOT/web/v2/app.js"
INDEX_HTML="$REPO_ROOT/web/v2/index.html"

ok()   { printf '\033[0;32mPASS\033[0m %s\n' "$*"; }
fail() { printf '\033[0;31mFAIL\033[0m %s\n' "$*"; exit 1; }

[[ -f "$APP_JS" ]]     || fail "missing $APP_JS"
[[ -f "$INDEX_HTML" ]] || fail "missing $INDEX_HTML"

# ── Test 1: Settings view has 3 threshold inputs + fleet kill toggle ───────
grep -q "id=\"cost-warn\"" "$APP_JS" || fail "missing #cost-warn input"
grep -q "id=\"cost-red\""  "$APP_JS" || fail "missing #cost-red input"
grep -q "id=\"cost-kill\"" "$APP_JS" || fail "missing #cost-kill input"
grep -q "id=\"cost-fleet-kill\"" "$APP_JS" || fail "missing fleet-kill toggle"
ok "Settings view: warn / red / kill thresholds + fleet-kill toggle present"

# ── Test 2: persistence via chumpPrefs cost.thresholds + cost.fleet_kill ──
grep -q "chumpPrefs?.set('cost.thresholds'"   "$APP_JS" || fail "thresholds not persisted via chumpPrefs"
grep -q "chumpPrefs?.get('cost.thresholds'"   "$APP_JS" || fail "thresholds not RESTORED from chumpPrefs"
grep -q "chumpPrefs?.set('cost.fleet_kill'"   "$APP_JS" || fail "fleet_kill not persisted"
ok "persistence: cost.thresholds + cost.fleet_kill via chumpPrefs"

# ── Test 3: validation — warn < red < kill, all ≥ 0 ────────────────────────
grep -q "warn must be less than red\|w < r" "$APP_JS" || fail "missing warn<red validation"
grep -q "red must be less than kill\|r < k"  "$APP_JS" || fail "missing red<kill validation"
ok "validation: warn < red < kill enforced"

# ── Test 4: fetch interceptor for 402 kill-switch ──────────────────────────
grep -q "window.fetch = async function" "$APP_JS" \
    || fail "missing window.fetch wrapper for 402 interception"
grep -q "res.status === 402" "$APP_JS" \
    || fail "fetch wrapper doesn't check status 402"
grep -q "session_cost_exceeded\|fleet_cost_exceeded" "$APP_JS" \
    || fail "missing canonical error-code matching"
ok "fetch wrapper: intercepts 402 + matches session/fleet cost exceeded"

# ── Test 5: kill-switch modal rendered with required content ──────────────
grep -q "cost-kill-modal" "$APP_JS"  || fail "missing .cost-kill-modal element"
grep -qE "role=\"alertdialog\"|setAttribute\('role', 'alertdialog'\)" "$APP_JS" \
    || fail "modal missing role=alertdialog"
grep -qE "aria-modal=\"true\"|setAttribute\('aria-modal', 'true'\)" "$APP_JS" \
    || fail "modal missing aria-modal"
grep -q "cost-kill-config\|Raise ceiling" "$APP_JS" || fail "missing 'Raise ceiling' CTA"
ok "kill modal: alertdialog + aria-modal + raise-ceiling CTA"

# ── Test 6: telemetry — kind=cost_threshold_changed + cost_threshold_crossed ──
grep -q "cost_threshold_changed" "$APP_JS" \
    || fail "missing kind=cost_threshold_changed telemetry"
grep -q "cost_threshold_crossed" "$APP_JS" \
    || fail "missing kind=cost_threshold_crossed telemetry"
grep -B5 "cost_threshold_crossed" "$APP_JS" | grep -q "sendBeacon" \
    || fail "telemetry should use sendBeacon"
ok "telemetry: cost_threshold_changed (on edit) + cost_threshold_crossed (on 402)"

# ── Test 7: reset button + chumpPrefs.del cleanup ──────────────────────────
grep -q "cost-threshold-reset" "$APP_JS" || fail "missing reset-to-defaults button"
grep -q "chumpPrefs?.del('cost.thresholds')" "$APP_JS" \
    || fail "reset should del cost.thresholds key"
ok "reset: chumpPrefs.del cleanup wired"

# ── Test 8: CSS for inputs + modal + buttons ──────────────────────────────
grep -q ".cost-threshold" "$INDEX_HTML"        || fail "missing .cost-threshold CSS"
grep -q ".cost-kill-modal" "$INDEX_HTML"       || fail "missing .cost-kill-modal CSS"
grep -q ".cost-kill-config" "$INDEX_HTML"      || fail "missing .cost-kill-config CSS"
grep -q ".cost-kill-dismiss" "$INDEX_HTML"     || fail "missing .cost-kill-dismiss CSS"
ok "CSS: threshold inputs + modal shell + button variants all styled"

# ── Test 9: provenance — PRODUCT-113 referenced ────────────────────────────
grep -q "PRODUCT-113" "$APP_JS" \
    || fail "code missing PRODUCT-113 provenance"
ok "provenance: PRODUCT-113 referenced in code"

# ── Test 10: status-footer cost slot reads chumpPrefs cost.thresholds ─────
# (Wired by PRODUCT-107; this gap maintains the contract.)
grep -q "chumpPrefs?.get('cost.thresholds'" "$APP_JS" \
    || fail "status footer / cost meter doesn't read chumpPrefs.cost.thresholds — integration broken"
ok "integration: cost meter + status footer read same chumpPrefs key"

# ── Test 11: 402 modal navigates to Settings on Raise-ceiling ─────────────
grep -A6 "cost-kill-config" "$APP_JS" | grep -q "chump:navigate.*settings\|'settings'" \
    || fail "Raise-ceiling button doesn't dispatch chump:navigate → settings"
ok "Raise-ceiling: navigates to Settings via chump:navigate"

# ── Test 12 (INFRA-1712): cost-tally path emits content_bot.cost_report,
# and a timed-out run must never surface as failure_class=permanent — a bare
# timeout is presumed retryable until something else classifies it otherwise.
BIN_DIR="${CARGO_TARGET_DIR:-$REPO_ROOT/target}/debug"
if [[ ! -x "$BIN_DIR/chump" ]]; then
    echo "test-pwa-cost-ceiling: building chump ($BIN_DIR/chump) …" >&2
    if ! command -v cargo >/dev/null 2>&1; then
        fail "cargo not on PATH — cannot run the content-bot cost-tally smoke test"
    fi
    ( cd "$REPO_ROOT" && cargo build -q --bin chump ) \
        || fail "cargo build failed — cannot run the content-bot cost-tally smoke test"
    [[ -x "$BIN_DIR/chump" ]] || fail "chump binary still missing after cargo build ($BIN_DIR/chump)"
fi

SMOKE_AMBIENT="$(mktemp -t chump-infra1712-ambient.XXXXXX)"
trap 'rm -f "$SMOKE_AMBIENT"' EXIT
CHUMP_AMBIENT_LOG="$SMOKE_AMBIENT" "$BIN_DIR/chump" waste-tally --content-bot-smoke-test \
    || fail "chump waste-tally --content-bot-smoke-test exited non-zero"

grep -q '"kind":"content_bot.cost_report"' "$SMOKE_AMBIENT" \
    || fail "cost-tally path did not emit content_bot.cost_report"
ok "cost-tally path: content_bot.cost_report event emitted"

TIMED_OUT_LINE="$(grep '"kind":"content_bot_run.timed_out"' "$SMOKE_AMBIENT" || true)"
[[ -n "$TIMED_OUT_LINE" ]] || fail "cost-tally path did not emit content_bot_run.timed_out"
if grep -q '"failure_class":"permanent"' <<< "$TIMED_OUT_LINE"; then
    fail "timed-out run classified as permanent — timeouts must default to transient"
fi
ok "outcome accounting: timed-out run is not classified permanent"

ok "ALL PRODUCT-113 cost-ceiling checks passed"
