#!/bin/bash
# chump-focus-mode.sh — kill non-essential processes and pause Spotlight before heavy Chump work.
# Run before overnight heartbeat sessions or when you need max GPU/RAM for vLLM-MLX (8000).
# Optional one-time setup to free more memory: disable Siri, photoanalysisd, suggestd, etc. (see docs/GPU_TUNING.md or header below).
#
# One-time (run yourself; not in this script):
#   sudo mdutil -a -i off   # Spotlight indexing off (turn back on: sudo mdutil -a -i on)
#   launchctl disable user/$(id -u)/com.apple.assistantd
#   launchctl disable user/$(id -u)/com.apple.Siri.agent
#   launchctl disable user/$(id -u)/com.apple.photoanalysisd
#   launchctl disable user/$(id -u)/com.apple.knowledge-agent
#   launchctl disable user/$(id -u)/com.apple.suggestd
#   launchctl disable user/$(id -u)/com.apple.gamed
#   launchctl disable user/$(id -u)/com.apple.sharingd   # if you don't need AirDrop
# Then kill running instances: killall -9 assistantd photoanalysisd suggestd knowledge-agent gamed 2>/dev/null

set -e
ROOT="${CHUMP_HOME:-$(cd "$(dirname "$0")/.." && pwd)}"
cd "$ROOT"

echo "Chump focus mode: killing non-essential processes..."

killall -9 Safari 2>/dev/null || true
killall -9 "Google Chrome" 2>/dev/null || true
killall -9 Cursor 2>/dev/null || true
killall -9 Mail 2>/dev/null || true
killall -9 Messages 2>/dev/null || true
killall -9 Music 2>/dev/null || true
killall -9 News 2>/dev/null || true
killall -9 Stocks 2>/dev/null || true
killall -9 photoanalysisd 2>/dev/null || true
killall -9 suggestd 2>/dev/null || true
killall -9 knowledge-agent 2>/dev/null || true

# Pause Spotlight indexing (frees CPU/memory). Re-enable later: sudo mdutil -a -i on
if command -v mdutil >/dev/null 2>&1; then
  if sudo -n mdutil -a -i off 2>/dev/null; then
    echo "Spotlight indexing paused (mdutil -a -i off)."
  else
    echo "Tip: run 'sudo mdutil -a -i off' to pause Spotlight for more headroom."
  fi
fi

echo ""
echo "Memory status (top 10 by RSS):"
ps -eo pid,rss,comm 2>/dev/null | sort -k2 -rn | head -10
echo ""
echo "Port 8000:"
curl -s -o /dev/null -w "%{http_code}" --max-time 2 http://127.0.0.1:8000/v1/models 2>/dev/null | grep -q 200 && echo "UP" || echo "DOWN"
echo "Done. Start Chump/heartbeat when ready."
