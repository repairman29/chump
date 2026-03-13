#!/data/data/com.termux/files/usr/bin/bash
# If the Mabel Discord bot is not running but llama-server is up, start the bot.
# Run from Pixel (Termux) in cron or from mabel-farmer so she recovers after downtime.
# Usage: bash ~/chump/scripts/ensure-mabel-bot-up.sh

set -e
cd ~/chump
if [[ -f .env ]]; then set -a; source .env; set +a; fi

if pgrep -f "chump.*--discord" >/dev/null 2>&1; then
  exit 0
fi

PORT="${CHUMP_PORT:-8000}"
if ! curl -s --max-time 3 "http://127.0.0.1:${PORT}/v1/models" >/dev/null 2>&1; then
  echo "ensure-mabel-bot-up: llama-server not ready on ${PORT}; skip starting bot." >&2
  exit 1
fi

[[ -z "$DISCORD_TOKEN" ]] && { echo "ensure-mabel-bot-up: DISCORD_TOKEN not set." >&2; exit 1; }

mkdir -p logs
nohup ./start-companion.sh --bot >> logs/companion.log 2>&1 </dev/null &
echo "ensure-mabel-bot-up: started Discord bot (pid $!)."
