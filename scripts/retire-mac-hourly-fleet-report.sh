#!/usr/bin/env bash
# Retire the Mac-only hourly Discord DM job once Mabel's report round is the single scheduled
# fleet report (logs/mabel-report-*.md + notify). Run on the Mac from the Chump repo root.
#
# Unloads LaunchAgent ai.chump.hourly-update-to-discord (same label as install-roles-launchd /
# hourly-update-to-discord.plist.example). Idempotent: safe if already unloaded.
#
# See docs/OPERATIONS.md "Single fleet report" and docs/ROADMAP_MABEL_DRIVER.md §2.1.

set -e
UID_NUM="$(id -u)"
DOMAIN="gui/${UID_NUM}"
SERVICE="ai.chump.hourly-update-to-discord"

echo "Attempting: launchctl bootout ${DOMAIN}/${SERVICE}"
if launchctl bootout "${DOMAIN}/${SERVICE}" 2>/dev/null; then
  echo "OK: unloaded ${SERVICE}"
else
  echo "SKIP: ${SERVICE} not loaded or already removed (exit ignored)."
fi

echo ""
echo "Next: confirm Mabel report round runs on the Pixel and on-demand !status works."
echo "Docs: docs/OPERATIONS.md (Single fleet report), docs/ROADMAP.md Fleet section."
