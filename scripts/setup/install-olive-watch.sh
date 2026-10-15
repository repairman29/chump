#!/bin/bash
set -euo pipefail

# Install the Olive post-launch watch daemon (PRODUCT-382)
# This sets up the daily reporting timer for the 14-day post-launch watch period
# starting from the 2026-10-10 Facebook ask.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$(dirname "$SCRIPT_DIR")")"
PLIST_SRC="$REPO_ROOT/launchd/com.chump.olive-watch.plist"
PLIST_DST="$HOME/Library/LaunchAgents/com.chump.olive-watch.plist"

# Ensure the source plist exists
if [[ ! -f "$PLIST_SRC" ]]; then
    echo "Error: Plist not found at $PLIST_SRC" >&2
    exit 1
fi

# Expand paths in the plist (replace /path/to/HOME with actual HOME)
mkdir -p "$(dirname "$PLIST_DST")"
sed "s|\$HOME|$HOME|g; s|/path/to/HOME|$HOME|g" "$PLIST_SRC" > "$PLIST_DST"

# Load the daemon
launchctl load "$PLIST_DST" || true

echo "Olive watch installed at $PLIST_DST"
echo "Status: launchctl list | grep com.chump.olive-watch"
echo "Logs: tail -F /tmp/olive-watch.{out,err}.log"
