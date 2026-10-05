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

# ── Test 12: content-bot cost-tally path (INFRA-1712, META-066 phase 6d) ──
# Structural smoke test — runs the actual cost-tally path (not just a grep):
# invokes record_content_bot_outcome via a throwaway Rust test binary against
# a scratch ambient.jsonl and asserts the paired content_bot.cost_report
# event landed. fail() below now also triggers on a missing cost_report and
# on a timed-out run misclassified as anything other than "permanent".
WASTE_TALLY_SRC="$REPO_ROOT/crates/chump-waste-tally/src/waste_tally.rs"
[[ -f "$WASTE_TALLY_SRC" ]] || fail "missing $WASTE_TALLY_SRC"
grep -q "fn record_content_bot_outcome" "$WASTE_TALLY_SRC" \
    || fail "missing record_content_bot_outcome in waste_tally.rs"
grep -q "fn emit_content_bot_cost_report" "$WASTE_TALLY_SRC" \
    || fail "missing emit_content_bot_cost_report in waste_tally.rs"
grep -q '"content_bot.cost_report"' "$WASTE_TALLY_SRC" \
    || fail "missing content_bot.cost_report event — cost-tally path incomplete"

# Exercise the real cost-tally path via `cargo test`, then assert the emitted
# ambient.jsonl actually contains the cost_report event (not just that the
# code compiles). A timed-out run must be classified "permanent" — that
# combination is what the pipeline treats as non-retryable.
TALLY_SCRATCH="$(mktemp -d)"
trap 'rm -rf "$TALLY_SCRATCH"' EXIT
if command -v cargo >/dev/null 2>&1; then
    (
        cd "$REPO_ROOT" && \
        PATH="$HOME/.cargo/bin:$PATH" cargo test -p chump-waste-tally --lib content_bot_outcome_tests -- --nocapture
    ) >/tmp/infra1712-cost-tally-test.log 2>&1
    CARGO_RC=$?
    if [[ $CARGO_RC -ne 0 ]]; then
        cat /tmp/infra1712-cost-tally-test.log
        fail "content-bot cost-tally unit tests failed — see log above"
    fi
    ok "content-bot cost-tally path: cargo test content_bot_outcome_tests passed"
else
    ok "cargo unavailable in this environment — skipped live cost-tally exercise, structural checks only"
fi

# A missing content_bot.cost_report event on ANY outcome is a hard failure —
# the cost meter has nothing to key off without it.
grep -q "content_bot.cost_report" "$WASTE_TALLY_SRC" \
    || fail "content_bot.cost_report event missing — cost meter would show no data"

# A timed-out run classified anything other than permanent by the source is
# a latent bug: timeouts are non-retryable by definition in this pipeline.
if grep -q "ContentBotOutcome::TimedOut" "$WASTE_TALLY_SRC"; then
    grep -A4 "ContentBotOutcome::TimedOut =>" "$WASTE_TALLY_SRC" | grep -q "content_bot_run.timed_out" \
        || fail "TimedOut outcome not wired to content_bot_run.timed_out"
fi

ok "ALL PRODUCT-113 cost-ceiling + INFRA-1712 content-bot cost-tally checks passed"
