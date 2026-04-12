#!/usr/bin/env bash
# Install and load launchd jobs for background roles (Farmer Brown, Heartbeat Shepherd,
# Memory Keeper, Doc Keeper, Sentinel, Oven Tender, Restart-vLLM-if-down, Hourly-update-to-Discord, Shed-load,
# COS weekly snapshot). Replaces /path/to/Chump with your repo path.
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
    doc-keeper.plist.example) echo "ai.chump.doc-keeper" ;;
    sentinel.plist.example) echo "ai.chump.sentinel" ;;
    oven-tender.plist.example) echo "ai.chump.oven-tender" ;;
    restart-vllm-if-down.plist.example) echo "ai.chump.restart-vllm-if-down" ;;
    hourly-update-to-discord.plist.example) echo "ai.chump.hourly-update-to-discord" ;;
    shed-load.plist.example) echo "ai.chump.shed-load" ;;
    cos-weekly-snapshot.plist.example) echo "ai.chump.cos-weekly-snapshot" ;;
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

for ex in farmer-brown.plist.example heartbeat-shepherd.plist.example memory-keeper.plist.example doc-keeper.plist.example sentinel.plist.example oven-tender.plist.example restart-vllm-if-down.plist.example hourly-update-to-discord.plist.example shed-load.plist.example cos-weekly-snapshot.plist.example; do
  install_one "$ex"
done

echo ""
echo "All roles are installed and loaded. They will run at:"
echo "  Farmer Brown:         every 120s (2 min)"
echo "  Heartbeat Shepherd:   every 15 min"
echo "  Memory Keeper:        every 15 min"
echo "  Doc Keeper:           every 6 h — broken relative links in docs (python3)"
echo "  Sentinel:             every 5 min"
echo "  Oven Tender:          every 1 hour"
echo "  Restart vLLM if down: every 180s (3 min) — keeps MLX oven on when Python crashes"
echo "  Hourly update to Discord: every 3600s (1 h) — DM summary to CHUMP_READY_DM_USER_ID"
echo "  Shed load:            every 7200s (2 h) — quit blocklisted apps (chump-mode.conf) for max GPU/RAM"
echo "  COS weekly snapshot:  Monday 08:00 — logs/cos-weekly-YYYY-MM-DD.md (requires sqlite3)"
echo "Logs: $ROOT/logs/*.log and Chump Menu → Roles tab (Open log)."
echo "To stop: ./scripts/unload-roles-launchd.sh"
