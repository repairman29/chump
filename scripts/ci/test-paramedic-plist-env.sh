#!/usr/bin/env bash
# test-paramedic-plist-env.sh — INFRA-1597
#
# Smoke test: scripts/setup/com.chump.paramedic.plist must declare the env
# vars / WorkingDirectory the daemon needs to run under launchd. Without
# these, cwd=/ and the daemon emits `r2d2: unable to open database file:
# /sessions/chump_memory.db` forever.
#
# Asserts on the source plist *template* (placeholders not yet substituted);
# the install script wires the actual values at install time.

set -uo pipefail

PASS=0
FAIL=0
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
PLIST="$REPO_ROOT/scripts/setup/com.chump.paramedic.plist"
INSTALLER="$REPO_ROOT/scripts/setup/install-paramedic.sh"

echo "=== INFRA-1597 paramedic plist env-var test ==="

if [[ ! -f "$PLIST" ]]; then
    fail "plist template not found at $PLIST"
    echo "FAIL"
    exit 1
fi
ok "plist template present"

# Use plutil for structured XML lint when available; fall back to grep.
if command -v plutil >/dev/null 2>&1; then
    if plutil -lint "$PLIST" >/dev/null 2>&1; then
        ok "plutil -lint passes"
    else
        fail "plutil -lint failed on $PLIST"
    fi
fi

# 1. WorkingDirectory key present.
if grep -q '<key>WorkingDirectory</key>' "$PLIST"; then
    ok "WorkingDirectory key present"
else
    fail "WorkingDirectory key missing — daemon will run with cwd=/"
fi

# 2. EnvironmentVariables block contains CHUMP_HOME, HOME, PATH.
EV_BLOCK="$(awk '/<key>EnvironmentVariables<\/key>/,/<\/dict>/' "$PLIST")"
for key in CHUMP_HOME HOME PATH; do
    if grep -q "<key>$key</key>" <<<"$EV_BLOCK"; then
        ok "EnvironmentVariables.${key} declared"
    else
        fail "EnvironmentVariables.${key} missing"
    fi
done

# 3. Installer substitutes the placeholders we added (otherwise the daemon
#    launches with literal placeholder strings in CHUMP_HOME).
for placeholder in CHUMP_REPO_ROOT_PLACEHOLDER USER_HOME_PLACEHOLDER CHUMP_HOME_PLACEHOLDER_DOTCARGO_BIN; do
    if grep -q "$placeholder" "$PLIST" && grep -q "s|$placeholder|" "$INSTALLER"; then
        ok "installer substitutes $placeholder"
    else
        fail "$placeholder appears in plist but installer does not substitute it"
    fi
done

# 4. PATH includes ~/.cargo/bin (INFRA-1556 pattern — chump may shell out to
#    cargo subcommands during rule execution).
PATH_VAL="$(awk '/<key>PATH<\/key>/{getline; print}' "$PLIST")"
if grep -q 'DOTCARGO_BIN\|\.cargo/bin' <<<"$PATH_VAL"; then
    ok "PATH includes cargo bin placeholder"
else
    fail "PATH does not include cargo bin"
fi

echo "==========================================="
echo "PASS=$PASS FAIL=$FAIL"
[[ "$FAIL" -eq 0 ]] || exit 1
exit 0
