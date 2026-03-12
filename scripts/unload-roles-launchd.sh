#!/usr/bin/env bash
# Unload all five role launchd jobs (stop auto-start). Does not delete the plist files.
#
# Usage: ./scripts/unload-roles-launchd.sh

set -e
LAUNCH_AGENTS="${HOME}/Library/LaunchAgents"

for label in ai.openclaw.farmer-brown ai.chump.heartbeat-shepherd ai.chump.memory-keeper ai.chump.sentinel ai.chump.oven-tender; do
  plist="$LAUNCH_AGENTS/${label}.plist"
  if [[ -f "$plist" ]]; then
    launchctl unload "$plist" 2>/dev/null && echo "Unloaded: $label" || echo "Not loaded or error: $label"
  fi
done
