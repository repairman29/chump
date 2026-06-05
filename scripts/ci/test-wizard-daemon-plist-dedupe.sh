#!/usr/bin/env bash
# RESILIENT-120: assert install-wizard-daemon-launchd.sh purges the legacy
# ai.chump.wizard-daemon.plist orphan (a split-brain footgun — if loaded it
# double-ticks at 180s running origin/main's divergent script vs the canonical
# 300s local one) on BOTH install and uninstall, and self-heals on re-install.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
INSTALLER="$REPO_ROOT/scripts/setup/install-wizard-daemon-launchd.sh"

FAILS=0
pass() { echo "  ok  $1"; }
fail() { echo "  ERR $1"; FAILS=$((FAILS + 1)); }

[[ -f "$INSTALLER" ]] || { echo "FAIL: installer not found at $INSTALLER"; exit 1; }

# Sandbox HOME so the installer writes to a throwaway LaunchAgents dir and
# launchctl unload (if present) only ever targets sandboxed paths.
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP"
mkdir -p "$HOME/Library/LaunchAgents"
LEGACY="$HOME/Library/LaunchAgents/ai.chump.wizard-daemon.plist"
CANON="$HOME/Library/LaunchAgents/com.chump.wizard-daemon.plist"

# --- Test 1: install purges a pre-existing legacy orphan + writes canonical ---
printf '<plist>legacy</plist>\n' > "$LEGACY"
bash "$INSTALLER" >/dev/null 2>&1 || true
[[ ! -e "$LEGACY" ]] && pass "install removes legacy ai.chump orphan" \
                     || fail "legacy orphan survived install"
[[ -e "$CANON" ]] && pass "install writes canonical com.chump plist" \
                  || fail "canonical plist missing after install"

# --- Test 2: uninstall also purges the legacy orphan ---
printf '<plist>legacy</plist>\n' > "$LEGACY"
bash "$INSTALLER" --uninstall >/dev/null 2>&1 || true
[[ ! -e "$LEGACY" ]] && pass "uninstall removes legacy ai.chump orphan" \
                     || fail "legacy orphan survived uninstall"

# --- Test 3: re-install self-heals a freshly-reappeared orphan (idempotent) ---
bash "$INSTALLER" >/dev/null 2>&1 || true
printf '<plist>legacy</plist>\n' > "$LEGACY"
bash "$INSTALLER" >/dev/null 2>&1 || true
[[ ! -e "$LEGACY" ]] && pass "re-install purges a reappeared orphan (self-heal)" \
                     || fail "orphan survived re-install"

if [[ "$FAILS" -eq 0 ]]; then
    echo "PASS test-wizard-daemon-plist-dedupe"
    exit 0
else
    echo "FAIL test-wizard-daemon-plist-dedupe ($FAILS failure(s))"
    exit 1
fi
