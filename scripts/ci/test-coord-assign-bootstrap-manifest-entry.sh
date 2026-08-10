#!/usr/bin/env bash
# scripts/ci/test-coord-assign-bootstrap-manifest-entry.sh — RESILIENT-294
#
# RESILIENT-271 shipped scripts/setup/install-coord-assign-launchd.sh (the
# FLEET-034 chump-coord assign push-routing daemon installer) and mapped it
# in optional-installers-allowlist.txt, but never registered it in
# bootstrap-manifest.yaml — the manifest chump-fleet-bootstrap.sh actually
# reads to auto-install on a fresh operator machine. Without a manifest
# entry the daemon is "known and intentional" per the audit list but never
# actually gets installed by `chump-fleet-bootstrap.sh`.
#
# This gate fails without the fix: it asserts the installer is registered
# as a manifest entry (not just present in the optional allowlist), and that
# the manifest's install/check commands point at the real installer script.

set -euo pipefail

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
MANIFEST="$REPO/scripts/setup/bootstrap-manifest.yaml"
INSTALLER="$REPO/scripts/setup/install-coord-assign-launchd.sh"

ok()   { printf '\033[0;32mPASS\033[0m %s\n' "$*"; }
fail() { printf '\033[0;31mFAIL\033[0m %s\n' "$*"; exit 1; }

[[ -f "$MANIFEST" ]] || fail "bootstrap-manifest.yaml not found"
[[ -x "$INSTALLER" ]] || fail "install-coord-assign-launchd.sh missing or not executable"
ok "manifest + installer present"

grep -q "id: chump-coord-assign-launchd" "$MANIFEST" \
    || fail "bootstrap-manifest.yaml has no chump-coord-assign-launchd entry"
ok "manifest has a chump-coord-assign-launchd entry"

# Extract the entry block (from its "- id:" line to the next "- id:" or EOF).
entry=$(awk '/- id: chump-coord-assign-launchd/{flag=1} flag{print} /- id: chump-coord-assign-launchd/{next} flag && /^  - id:/{exit}' "$MANIFEST")

echo "$entry" | grep -q "install-coord-assign-launchd.sh" \
    || fail "manifest entry's install/check commands do not reference install-coord-assign-launchd.sh"
ok "manifest entry install/check reference the real installer script"

echo "$entry" | grep -q "check:.*--check" \
    || fail "manifest entry's check command does not use the installer's --check flag"
ok "manifest entry check command uses installer's --check flag"

# Cross-check against the coverage gate this entry feeds: bootstrap-manifest
# coverage should no longer list install-coord-assign-launchd.sh as unmapped.
if bash "$REPO/scripts/ci/test-bootstrap-manifest-coverage.sh" 2>&1 | grep -q "install-coord-assign-launchd.sh"; then
    fail "install-coord-assign-launchd.sh still reported unmapped by bootstrap-manifest coverage gate"
fi
ok "bootstrap-manifest coverage gate no longer reports install-coord-assign-launchd.sh unmapped"

echo
echo "All checks passed."
