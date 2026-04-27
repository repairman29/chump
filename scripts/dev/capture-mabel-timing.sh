#!/usr/bin/env bash
# SSH to the Pixel (Termux), ensure CHUMP_LOG_TIMING=1, then capture [timing] lines
# while you send Discord messages to Mabel. Prints when to send queries and then
# parses and summarizes the results.
#
# Usage: ./scripts/dev/capture-mabel-timing.sh [--yes] [ssh_host] [capture_seconds]
#   --yes: skip the "bot already running?" prompt (use when running non-interactively).
#   ssh_host: SSH host (default: termux). Must have ~/chump and companion.log.
#   capture_seconds: how long to tail the log (default: 90).
#
# Example: ./scripts/dev/capture-mabel-timing.sh termux 120
#          ./scripts/dev/capture-mabel-timing.sh --yes termux 90
# Run from the Chump repo root when the Pixel is on the same network (or Tailscale).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SKIP_PROMPT=0
SSH_HOST=""
CAPTURE_SEC=""
for arg in "$@"; do
  case "$arg" in
    --yes) SKIP_PROMPT=1 ;;
    *) if [[ -z "$SSH_HOST" ]]; then SSH_HOST="$arg"; elif [[ -z "$CAPTURE_SEC" ]]; then CAPTURE_SEC="$arg"; fi ;;
  esac
done
[[ -n "$SSH_HOST" ]] || SSH_HOST="termux"
[[ -n "$CAPTURE_SEC" ]] || CAPTURE_SEC="90"

echo "==> Connecting to $SSH_HOST to ensure CHUMP_LOG_TIMING=1 and capture timing..."
# Ensure timing is enabled (append if missing)
ssh "$SSH_HOST" 'grep -q "CHUMP_LOG_TIMING" ~/chump/.env 2>/dev/null || echo "CHUMP_LOG_TIMING=1" >> ~/chump/.env; grep CHUMP_LOG_TIMING ~/chump/.env'
echo ""
if [[ $SKIP_PROMPT -eq 0 ]]; then
  echo "If you just added CHUMP_LOG_TIMING=1, restart the bot on the Pixel first:"
  echo "  pkill -f \"chump --discord\"; cd ~/chump && nohup ./start-companion.sh --bot >> ~/chump/logs/companion.log 2>&1 &"
  echo ""
  read -r -p "Is the bot already running with timing enabled? (y/n) " yn
  case "$yn" in
    [yY]) ;;
    *) echo "Start the bot on the Pixel, then run this script again."; exit 0 ;;
  esac
fi

CAPTURE_FILE="$REPO_ROOT/docs/mabel-timing-capture.txt"

echo ""
echo "==> Capturing [timing] lines for ${CAPTURE_SEC} seconds."
echo "    Send 5–7 messages to Mabel in Discord now (short reply, memory, tools)."
echo ""
ssh "$SSH_HOST" "timeout ${CAPTURE_SEC} tail -f ~/chump/logs/companion.log 2>/dev/null | grep --line-buffered '\[timing\]' || true" > "$CAPTURE_FILE"

if [[ ! -s "$CAPTURE_FILE" ]]; then
  echo "No timing lines captured. Is companion.log being written? Try: ssh $SSH_HOST 'tail -5 ~/chump/logs/companion.log'"
  exit 1
fi

echo "==> Captured $(wc -l < "$CAPTURE_FILE") timing lines. Parsing..."
echo ""
"$SCRIPT_DIR/parse-timing-log.sh" --summary "$CAPTURE_FILE"
echo ""
echo "Done. Raw timing lines saved to docs/mabel-timing-capture.txt. Copy to docs/mabel-timing-baseline.txt to keep as baseline."
