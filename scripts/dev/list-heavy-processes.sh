#!/usr/bin/env bash
# List processes using the most RAM (and optionally known GPU-heavy apps) so you can
# add them to scripts/dev/chump-mode.conf to give more headroom to vLLM-MLX / Python.
# Run before "Enter Chump mode" to see what to close.
#
# Usage: ./scripts/dev/list-heavy-processes.sh [N]
#   N = number of top processes to show (default 25). Output also written to logs/heavy-processes.log

set -e
ROOT="${CHUMP_HOME:-$(cd "$(dirname "$0")/.." && pwd)}"
cd "$ROOT"
mkdir -p "$ROOT/logs"
LOG="$ROOT/logs/heavy-processes.log"
TOP_N="${1:-25}"

# RSS on macOS ps is in bytes for -o rss; some ps show KB. Normalize: show MB.
echo "=== Top $TOP_N processes by memory (RSS) ===" | tee "$LOG"
echo "" | tee -a "$LOG"
if command -v ps &>/dev/null; then
  # macOS: ps -eo pid,rss,comm (rss in KB). Show MB, sort descending, head -N.
  ps -eo pid,rss,comm 2>/dev/null | awk 'NR>1 { rss=$2/1024; if(rss>0) printf "%6.1f MB  pid %-7s %s\n", rss, $1, $3 }' | sort -k1 -rn | head -n "$TOP_N" | tee -a "$LOG"
else
  echo "ps not found" | tee -a "$LOG"
fi

echo "" | tee -a "$LOG"
echo "=== Known GPU / heavy apps currently running (add to chump-mode.conf to close in Chump mode) ===" | tee -a "$LOG"
# Process names that are often heavy; if any are running, list them.
HEAVY_NAMES="Google Chrome Safari Firefox Microsoft Edge Arc Brave Slack Discord Zoom Teams Code Cursor Electron Notion Obsidian Figma Mail Calendar Music TV"
for name in $HEAVY_NAMES; do
  if pgrep -x "$name" >/dev/null 2>&1 || pgrep -f "$name" >/dev/null 2>&1; then
    echo "  RUNNING: $name" | tee -a "$LOG"
  fi
done

echo "" | tee -a "$LOG"
echo "=== System memory summary ===" | tee -a "$LOG"
if command -v vm_stat &>/dev/null; then
  vm_stat | tee -a "$LOG"
fi

echo "" | tee -a "$LOG"
echo "Log written to $LOG — uncomment matching names in scripts/dev/chump-mode.conf then run Enter Chump mode." | tee -a "$LOG"
