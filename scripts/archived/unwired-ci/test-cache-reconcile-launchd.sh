#!/usr/bin/env bash
# scripts/ci/test-cache-reconcile-launchd.sh — INFRA-1105
#
# Static verification of the github-cache-reconcile LaunchAgent assets.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PLIST="$REPO_ROOT/launchd/com.chump.github-cache-reconcile.plist"
INST="$REPO_ROOT/scripts/setup/install-github-cache-reconcile-launchd.sh"
RECONCILE="$REPO_ROOT/scripts/ops/github-cache-reconcile.sh"

ok()   { printf '\033[0;32mPASS\033[0m %s\n' "$*"; }
fail() { printf '\033[0;31mFAIL\033[0m %s\n' "$*"; exit 1; }

[[ -f "$PLIST" ]] || fail "plist missing: $PLIST"
grep -q 'com.chump.github-cache-reconcile' "$PLIST" || fail "plist label wrong"
grep -q '<integer>300</integer>' "$PLIST" || fail "plist interval not 300s"
grep -q 'github-cache-reconcile.sh' "$PLIST" || fail "plist doesn't reference reconcile script"
ok "plist present with label + 5min interval + correct script reference"

[[ -x "$INST" ]] || fail "installer missing or not executable"
grep -q 'resolve_main_worktree' "$INST" || fail "installer not using INFRA-451 resolver"
grep -q 'launchctl bootstrap' "$INST" || fail "installer doesn't bootstrap"
grep -q 'CHUMP_RECONCILE_INTERVAL' "$INST" || fail "no test-override knob"
ok "installer present + uses resolve_main_worktree + has interval override"

# Reconcile script (shipped by INFRA-1081) must exist for plist to make sense.
[[ -x "$RECONCILE" ]] || fail "reconcile script missing from main (INFRA-1081 dep)"
ok "INFRA-1081 reconcile script present in main"

echo
echo "All INFRA-1105 cache-reconcile-launchd tests passed."
