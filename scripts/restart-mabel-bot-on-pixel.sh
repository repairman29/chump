#!/usr/bin/env bash
# Restart Mabel's Discord bot on the Pixel via SSH. Use from the Mac when Mabel's chat
# is stuck (e.g. "circuit open for 30s") or the bot died. Clears in-memory circuit state.
#
# Usage: ./scripts/restart-mabel-bot-on-pixel.sh
# Env: PIXEL_SSH_HOST (default termux), PIXEL_SSH_PORT (default 8022). Source .env or export.

set -e
ROOT="${CHUMP_HOME:-$(cd "$(dirname "$0")/.." && pwd)}"
cd "$ROOT"
if [[ -f .env ]]; then
  set -a
  source .env
  set +a
fi

SSH_HOST="${PIXEL_SSH_HOST:-termux}"
SSH_PORT="${PIXEL_SSH_PORT:-8022}"

echo "Restarting Mabel Discord bot on Pixel ($SSH_HOST:$SSH_PORT)..."
ssh -o ConnectTimeout=10 -o BatchMode=yes -p "$SSH_PORT" "$SSH_HOST" 'cd ~/chump && pkill -f "chump.*--discord" 2>/dev/null || true; sleep 2; ( ./start-companion.sh --bot >> logs/companion.log 2>&1 & ); sleep 5; if pgrep -f "chump.*--discord" >/dev/null 2>&1; then echo "Mabel bot started."; exit 0; else echo "Bot may still be starting or failed. Check ~/chump/logs/companion.log on Pixel."; exit 0; fi' || true
echo "Done."
