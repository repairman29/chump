#!/usr/bin/env bash
# scripts/setup/install-disk-critical-reactor-launchd.sh — INFRA-2304
#
# Installs the disk-critical-reactor as a long-lived launchd KeepAlive process
# that consumes disk_critical events from ambient.jsonl and triggers reactive
# escalation (reaper at higher tier, operator-recall if reaper insufficient).
#
# Idempotent: if already loaded, bootout-then-bootstrap to pick up plist changes.

set -euo pipefail

REPO_ROOT="${CHUMP_REPO:-/Users/jeffadkins/Projects/Chump}"
LABEL="dev.chump.disk-critical-reactor"
SRC_PLIST="$REPO_ROOT/scripts/plists/${LABEL}.plist"
DST_PLIST="$HOME/Library/LaunchAgents/${LABEL}.plist"
UID_DOMAIN="gui/$(id -u)"

if [[ ! -f "$SRC_PLIST" ]]; then
  echo "ERROR: source plist not found at $SRC_PLIST" >&2
  exit 1
fi

mkdir -p "$HOME/Library/LaunchAgents"
cp "$SRC_PLIST" "$DST_PLIST"
chmod 644 "$DST_PLIST"

# Bootout if currently loaded (idempotent reload).
if launchctl print "${UID_DOMAIN}/${LABEL}" >/dev/null 2>&1; then
  launchctl bootout "${UID_DOMAIN}/${LABEL}" 2>/dev/null || true
fi

# Bootstrap.
launchctl bootstrap "$UID_DOMAIN" "$DST_PLIST"
launchctl enable "${UID_DOMAIN}/${LABEL}"
launchctl kickstart "${UID_DOMAIN}/${LABEL}" 2>/dev/null || true

echo "✓ installed $LABEL"
echo "  plist  : $DST_PLIST"
echo "  status : $(launchctl print "${UID_DOMAIN}/${LABEL}" 2>/dev/null | grep -E 'state =|last exit code' | head -2)"
echo
echo "Verify with:"
echo "  tail -F /tmp/chump-disk-critical-reactor.out.log"
echo
echo "Emit a synthetic disk_critical to test (will run real reaper if disk is tight):"
echo '  printf "{\"ts\":\"%s\",\"kind\":\"disk_critical\",\"reaper\":\"test\"}\n" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> .chump-locks/ambient.jsonl'
