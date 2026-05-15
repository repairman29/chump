#!/usr/bin/env bash
# scripts/ci/test-pwa-config-dials.sh — PRODUCT-118

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
COMP="$REPO_ROOT/web/v2/config-dials.js"
INDEX="$REPO_ROOT/web/v2/index.html"
APP="$REPO_ROOT/web/v2/app.js"
SERVER="$REPO_ROOT/src/web_server.rs"

ok()   { printf '\033[0;32mPASS\033[0m %s\n' "$*"; }
fail() { printf '\033[0;31mFAIL\033[0m %s\n' "$*"; exit 1; }

# 1. Component file + custom element
[[ -f "$COMP" ]] || fail "component file missing: $COMP"
grep -q "customElements.define('chump-config-dials'" "$COMP" \
    || fail "chump-config-dials not defined"
ok "config-dials.js defines <chump-config-dials>"

# 2. 6 dials present
for key in CHUMP_GH_MAX_CALLS_PER_MIN FLEET_SIZE FLEET_MODEL CHUMP_WORK_BACKEND \
           CHUMP_AUTH_MODE CHUMP_ROUND_PRIVACY; do
    grep -q "'$key'" "$COMP" || fail "missing dial key: $key"
done
ok "all 6 operator dials defined in DIALS array"

# 3. Reads from /api/settings (existing INFRA-988 endpoint)
grep -q "/api/settings" "$COMP" || fail "missing /api/settings fetch"
ok "reads from /api/settings (INFRA-988 backend)"

# 4. Writes via POST /api/settings/{key}
grep -q "POST" "$COMP" || fail "missing POST"
grep -q "encodeURIComponent(key)" "$COMP" || fail "key not URL-encoded in apply"
ok "writes via POST /api/settings/{key}"

# 5. Edit-in-place draft state + Apply/Cancel buttons
grep -q "_editing" "$COMP" || fail "no draft state"
grep -q "_apply" "$COMP"   || fail "no _apply handler"
grep -q "_cancel" "$COMP"  || fail "no _cancel handler"
ok "edit-in-place with Apply + Cancel buttons"

# 6. Pending-state guard
grep -q "_pending" "$COMP" || fail "no _pending state guard"
ok "buttons disabled while POST in-flight"

# 7. Source badge (env / config / default)
grep -q "src-env"     "$COMP" || fail "no env source badge style"
grep -q "src-config"  "$COMP" || fail "no config source badge style"
grep -q "src-default" "$COMP" || fail "no default source badge style"
ok "source badge rendered (env / config / default)"

# 8. Auth header
grep -q "X-Chump-Auth" "$COMP" || fail "missing X-Chump-Auth header"
ok "sends X-Chump-Auth header (INFRA-1014 middleware)"

# 9. HTML-escape for XSS safety
grep -q "_esc" "$COMP" || fail "no _esc helper"
ok "HTML-escapes values to prevent XSS"

# 10. Wired in app.js VIEWS factory
grep -q "config:.*chump-config-dials" "$APP" \
    || fail "VIEWS map doesn't bind config -> chump-config-dials"
ok "config view bound in app.js VIEWS factory"

# 11. Script tag in index.html
grep -q 'src="config-dials.js"' "$INDEX" \
    || fail "index.html missing config-dials.js script tag"
ok "config-dials.js script tag in index.html"

# 12. Backend: SETTINGS_KEYS extended with new keys
grep -q '"CHUMP_GH_MAX_CALLS_PER_MIN"' "$SERVER" \
    || fail "SETTINGS_KEYS missing CHUMP_GH_MAX_CALLS_PER_MIN"
grep -q '"CHUMP_WORK_BACKEND"' "$SERVER" \
    || fail "SETTINGS_KEYS missing CHUMP_WORK_BACKEND"
ok "backend SETTINGS_KEYS extended with throttle + work-backend"

# 13. Backend: validators present
grep -qE 'CHUMP_GH_MAX_CALLS_PER_MIN.*1.*600|1.*=600.*contains' "$SERVER" \
    || fail "CHUMP_GH_MAX_CALLS_PER_MIN validator missing range 1..600"
grep -qE '"claude" \| "opencode" \| "aider"' "$SERVER" \
    || fail "CHUMP_WORK_BACKEND validator missing backend allowlist"
ok "backend validators reject invalid values"

# 14. Backend: defaults wired
grep -q '"CHUMP_GH_MAX_CALLS_PER_MIN" => "60"' "$SERVER" \
    || fail "CHUMP_GH_MAX_CALLS_PER_MIN default not 60"
grep -q '"CHUMP_WORK_BACKEND" => "claude"' "$SERVER" \
    || fail "CHUMP_WORK_BACKEND default not claude"
ok "backend defaults wired (throttle=60, work-backend=claude)"

echo
echo "All PRODUCT-118 config-dials tests passed."
