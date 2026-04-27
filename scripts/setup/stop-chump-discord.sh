#!/usr/bin/env bash
# Stop all Chump Discord bot processes. Run from repo root or scripts/.
# Use before starting Chump to avoid duplicate replies (each process replies to every message).

set -e
count=0
while pgrep -f "chump.*--discord" >/dev/null 2>&1 || pgrep -f "rust-agent.*--discord" >/dev/null 2>&1; do
  pkill -f "chump.*--discord" 2>/dev/null || true
  pkill -f "rust-agent.*--discord" 2>/dev/null || true
  count=$((count + 1))
  sleep 0.5
done
if [[ $count -gt 0 ]]; then
  echo "Stopped $count Chump Discord process(es)."
else
  echo "No Chump Discord process was running."
fi
