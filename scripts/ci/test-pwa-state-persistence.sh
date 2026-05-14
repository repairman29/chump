#!/usr/bin/env bash
# scripts/ci/test-pwa-state-persistence.sh — INFRA-1280
#
# Structural test for the PWA state-persistence helper.
# Verifies the chumpPrefs API + key wiring + schema-doc presence.
#
# (End-to-end DOM persistence across reload is exercised by the e2e-pwa job;
# this structural test catches regressions in the wiring layer cheaply.)

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
APP_JS="$REPO_ROOT/web/v2/app.js"
INDEX_HTML="$REPO_ROOT/web/v2/index.html"
SCHEMA="$REPO_ROOT/docs/api/PWA_STATE_SCHEMA.md"

ok()   { printf '\033[0;32mPASS\033[0m %s\n' "$*"; }
fail() { printf '\033[0;31mFAIL\033[0m %s\n' "$*"; exit 1; }

[[ -f "$APP_JS" ]]     || fail "missing $APP_JS"
[[ -f "$INDEX_HTML" ]] || fail "missing $INDEX_HTML"
[[ -f "$SCHEMA" ]]     || fail "missing schema doc $SCHEMA"

# ── Test 1: chumpPrefs helper exists with the four core methods ─────────────
grep -q "window.chumpPrefs = window.chumpPrefs || " "$APP_JS" \
    || fail "app.js missing chumpPrefs IIFE assignment"
for fn in 'get(key, fallback' 'set(key, value)' 'del(key)' 'resetAll()'; do
    grep -q "$fn" "$APP_JS" || fail "chumpPrefs missing method: $fn"
done
ok "chumpPrefs helper: get/set/del/resetAll all present"

# ── Test 2: every set() emits pwa_pref_changed telemetry ────────────────────
grep -q "pwa_pref_changed" "$APP_JS" \
    || fail "chumpPrefs.set should emit kind=pwa_pref_changed for adoption telemetry"
grep -q "sendBeacon" "$APP_JS" \
    || fail "telemetry path should use sendBeacon (non-blocking, best-effort)"
ok "telemetry: pwa_pref_changed emitted via sendBeacon on every set()"

# ── Test 3: try/catch wrappers prevent corruption from breaking UI ─────────
grep -A2 "get(key, fallback" "$APP_JS" | grep -q "try {" \
    || fail "chumpPrefs.get must wrap localStorage call in try/catch"
grep -A2 "set(key, value)" "$APP_JS" | grep -q "try {" \
    || fail "chumpPrefs.set must wrap localStorage call in try/catch"
ok "corruption-safe: both get + set wrap localStorage in try/catch"

# ── Test 4: theme applied BEFORE first paint (no flash) ─────────────────────
# Look for the IIFE that sets data-theme right after chumpPrefs definition.
grep -q "document.documentElement.setAttribute('data-theme'" "$APP_JS" \
    || fail "theme not applied to <html data-theme=...> — would flash on reload"
grep -q "prefers-color-scheme" "$APP_JS" \
    || fail "system theme should follow prefers-color-scheme media query"
ok "theme: applied to <html data-theme> on boot + follows prefers-color-scheme"

# ── Test 5: theme CSS variants present in index.html ────────────────────────
for theme in light "high-contrast"; do
    grep -q "html\[data-theme=\"$theme\"\]" "$INDEX_HTML" \
        || fail "index.html missing data-theme=\"$theme\" CSS rule"
done
ok "theme: light + high-contrast CSS variants both defined"

# ── Test 6: queue filter persistence — restore + persist + clear ───────────
grep -q "#restoreFilters" "$APP_JS"   || fail "queue view missing #restoreFilters"
grep -q "#persistFilters" "$APP_JS"   || fail "queue view missing #persistFilters"
grep -q "#clearFilters" "$APP_JS"     || fail "queue view missing #clearFilters"
grep -q "chumpPrefs.get('queue.filters'" "$APP_JS" \
    || fail "queue.filters read path not wired to chumpPrefs"
grep -q "chumpPrefs.set('queue.filters'" "$APP_JS" \
    || fail "queue.filters write path not wired to chumpPrefs"
ok "queue.filters: restore + persist + clear all wired via chumpPrefs"

# ── Test 7: queue URL reflection works alongside localStorage ──────────────
grep -q "URLSearchParams" "$APP_JS" \
    || fail "queue filter restore must check URL query params"
grep -q "history.replaceState" "$APP_JS" \
    || fail "queue filter persist must replaceState (not pushState) per AC"
ok "queue.filters: URL ?q=&status=... reflection + replaceState"

# ── Test 8: clear button exists in DOM template ─────────────────────────────
grep -q "id=\"gap-filter-clear\"" "$APP_JS" \
    || fail "Clear button missing from gap-search-bar template"
grep -q "gap-filter-clear" "$INDEX_HTML" \
    || fail "index.html missing .gap-filter-clear CSS rule"
ok "queue.filters: Clear button + CSS present"

# ── Test 9: Settings view exposes theme toggle + Reset-all ──────────────────
grep -q "name=\"chump-theme\"" "$APP_JS" \
    || fail "Settings view missing radio group for theme"
grep -q "#wireThemeToggle" "$APP_JS" \
    || fail "Settings view missing #wireThemeToggle wiring"
grep -q "chump-prefs-reset" "$APP_JS" \
    || fail "Settings view missing #chump-prefs-reset button"
grep -q "#wireResetButton" "$APP_JS" \
    || fail "Settings view missing #wireResetButton wiring"
grep -q "chumpPrefs.resetAll" "$APP_JS" \
    || fail "Reset button must invoke chumpPrefs.resetAll()"
ok "Settings view: theme radios + Reset-all button + handlers all present"

# ── Test 10: schema doc enumerates every implemented key ────────────────────
for key in "chump.theme" "chump.queue.filters"; do
    grep -q "\`$key\`" "$SCHEMA" \
        || fail "PWA_STATE_SCHEMA.md missing entry for $key"
done
grep -q "Privacy contract" "$SCHEMA" \
    || fail "PWA_STATE_SCHEMA.md missing privacy section"
grep -q "Migration safety" "$SCHEMA" \
    || fail "PWA_STATE_SCHEMA.md missing migration-safety section"
ok "schema doc: theme + queue.filters documented; privacy + migration sections present"

# ── Test 11: a11y — theme radios in a role=radiogroup ───────────────────────
grep -q "role=\"radiogroup\"" "$APP_JS" \
    || fail "theme radios should live in a role=radiogroup container"
grep -q "aria-label=\"Theme\"" "$APP_JS" \
    || fail "theme radiogroup should have aria-label"
ok "a11y: theme controls in proper role=radiogroup"

ok "ALL INFRA-1280 (Sub-gaps 2, 4, 9 core + cross-cutting) checks passed"
