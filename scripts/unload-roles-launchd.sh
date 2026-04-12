#!/usr/bin/env bash
# Unload role launchd jobs (stop auto-start). Does not delete the plist files.
#
# Usage: ./scripts/unload-roles-launchd.sh

set -e
LAUNCH_AGENTS="${HOME}/Library/LaunchAgents"

for label in ai.openclaw.farmer-brown ai.chump.heartbeat-shepherd ai.chump.memory-keeper ai.chump.doc-keeper ai.chump.sentinel ai.chump.oven-tender ai.chump.restart-vllm-if-down ai.chump.hourly-update-to-discord ai.chump.shed-load ai.chump.cos-weekly-snapshot; do
  plist="$LAUNCH_AGENTS/${label}.plist"
  if [[ -f "$plist" ]]; then
    launchctl unload "$plist" 2>/dev/null && echo "Unloaded: $label" || echo "Not loaded or error: $label"
  fi
done
