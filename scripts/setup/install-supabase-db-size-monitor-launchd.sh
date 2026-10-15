#!/usr/bin/env bash
# scripts/setup/install-supabase-db-size-monitor-launchd.sh
#
# Install the Supabase database size monitor as a launchd daemon (PRODUCT-378).
# Runs daily to monitor Olive's Supabase database size.
#
# Usage:
#   bash scripts/setup/install-supabase-db-size-monitor-launchd.sh
#
# Env:
#   OLIVE_SUPABASE_URL   Project URL (required for daemon to function)
#   OLIVE_SUPABASE_KEY   Service role key (required for daemon to function)

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

PLIST_SRC="$REPO_ROOT/launchd/com.chump.supabase-db-size-monitor.plist"
PLIST_DEST="$HOME/Library/LaunchAgents/com.chump.supabase-db-size-monitor.plist"

if [[ ! -f "$PLIST_SRC" ]]; then
    echo "ERROR: plist template not found at $PLIST_SRC"
    exit 1
fi

echo "Installing Supabase database size monitor launchd daemon…"

# Copy the plist file
mkdir -p "$(dirname "$PLIST_DEST")"
cp "$PLIST_SRC" "$PLIST_DEST"
echo "✓ Copied $PLIST_SRC → $PLIST_DEST"

# Load the daemon
launchctl load "$PLIST_DEST" 2>/dev/null || {
    # If already loaded, unload and reload
    launchctl unload "$PLIST_DEST" 2>/dev/null || true
    launchctl load "$PLIST_DEST"
}
echo "✓ Loaded daemon"

# Verify it's loaded
if launchctl list | grep -q com.chump.supabase-db-size-monitor; then
    echo "✓ Daemon is running: com.chump.supabase-db-size-monitor"
else
    echo "WARN: Daemon loaded but not currently active"
fi

echo ""
echo "Installation complete. The daemon will run daily."
echo ""
echo "To test the monitor immediately:"
echo "  bash $REPO_ROOT/scripts/ops/supabase-db-size-monitor.sh"
echo ""
echo "To view logs:"
echo "  tail -f /var/log/com.chump.supabase-db-size-monitor.log"
echo ""
echo "Required environment variables for the daemon:"
echo "  OLIVE_SUPABASE_URL   (https://<project>.supabase.co)"
echo "  OLIVE_SUPABASE_KEY   (service role key)"
echo ""
echo "Set these in your ~/.bashrc or ~/.zshrc for persistent configuration."
