#!/usr/bin/env bash
# Install and load launchd jobs for all five background roles (Farmer Brown, Heartbeat Shepherd,
# Memory Keeper, Sentinel, Oven Tender). Replaces /path/to/Chump with your repo path.
#
# Usage:
#   ./scripts/install-roles-launchd.sh              # use CHUMP_HOME or script dir/..
#   CHUMP_HOME=/Users/you/Projects/Chump ./scripts/install-roles-launchd.sh
#
# Unload (stop auto-start): run unload-roles-launchd.sh or launchctl unload ~/Library/LaunchAgents/ai.chump.* ...

set -e
ROOT="${CHUMP_HOME:-$(cd "$(dirname "$0")/.." && pwd)}"
ROOT="$(cd "$ROOT" && pwd)"
LAUNCH_AGENTS="${HOME}/Library/LaunchAgents"
mkdir -p "$ROOT/logs"
mkdir -p "$LAUNCH_AGENTS"

get_label() {
  case "$1" in
    farmer-brown.plist.example) echo "ai.openclaw.farmer-brown" ;;
    heartbeat-shepherd.plist.example) echo "ai.chump.heartbeat-shepherd" ;;
    memory-keeper.plist.example) echo "ai.chump.memory-keeper" ;;
    sentinel.plist.example) echo "ai.chump.sentinel" ;;
    oven-tender.plist.example) echo "ai.chump.oven-tender" ;;
    *) echo "" ;;
  esac
}

install_one() {
  local example="$1"
  local label
  label="$(get_label "$example")"
  local src="$ROOT/scripts/$example"
  local dest="$LAUNCH_AGENTS/${label}.plist"
  if [[ ! -f "$src" ]]; then
    echo "Skip (missing): $example"
    return 0
  fi
  sed "s|/path/to/Chump|$ROOT|g" "$src" | sed "s|/Users/you|$HOME|g" > "$dest"
  echo "Installed: $dest"
  launchctl unload "$dest" 2>/dev/null || true
  launchctl load "$dest"
  echo "  Loaded: $label"
}

echo "Chump repo: $ROOT"
echo "LaunchAgents: $LAUNCH_AGENTS"
echo ""

for ex in farmer-brown.plist.example heartbeat-shepherd.plist.example memory-keeper.plist.example sentinel.plist.example oven-tender.plist.example; do
  install_one "$ex"
done

echo ""
echo "All five roles are installed and loaded. They will run at:"
echo "  Farmer Brown:     every 120s (2 min)"
echo "  Heartbeat Shepherd: every 15 min"
echo "  Memory Keeper:    every 15 min"
echo "  Sentinel:         every 5 min"
echo "  Oven Tender:      every 1 hour"
echo "Logs: $ROOT/logs/*.log and Chump Menu → Roles tab (Open log)."
echo "To stop: launchctl unload ~/Library/LaunchAgents/ai.openclaw.farmer-brown.plist (and ai.chump.*)."
