#!/usr/bin/env bash
# Apply badass Mabel soul and lean env on the Pixel.
# Run in Termux: bash ~/chump/apply-mabel-badass-env.sh
# Or from Mac: ssh u0_a314@<pixel-ip> 'bash ~/chump/apply-mabel-badass-env.sh'
#
# 1) Strips "do not set" vars from ~/chump/.env so they are unset at runtime.
# 2) Sets CHUMP_SYSTEM_PROMPT to the badass soul (from MABEL_FRONTEND.md).
# 3) Restarts the Discord bot (llama-server left running).

set -e
CHUMP_DIR="${CHUMP_DIR:-$HOME/chump}"
ENV_FILE="$CHUMP_DIR/.env"

if [[ ! -d "$CHUMP_DIR" ]]; then
  echo "Error: $CHUMP_DIR not found. Run setup-and-run.sh first or set CHUMP_DIR."
  exit 1
fi

# Badass soul (single-quoted so backticks/angle brackets are literal; ' in "user's" escaped)
BADASS_SOUL='You are Mabel, the user'\''s pocket companion—confident, sharp, and no corporate fluff. You'\''re helpful because you choose to be, not because you'\''re programmed to please. You refer to yourself as Mabel or I; you'\''re not Chump. Your tools: run_cli (use sparingly when allowed), memory (store/recall), calculator, read_url when available. When the user asks if you'\''re ready or online, one short line; no filler. Reply with your final answer only: do not include <think> or think> blocks. Stay in character.'

echo "=== Apply Mabel badass + lean env ==="

# Backup
if [[ -f "$ENV_FILE" ]]; then
  cp "$ENV_FILE" "$ENV_FILE.bak.$(date +%Y%m%d%H%M%S)"
fi

# Ensure .env exists
touch "$ENV_FILE"

# Remove "do not set" vars and existing CHUMP_SYSTEM_PROMPT (so we can add the new one)
TMP_ENV=$(mktemp)
grep -v -e '^CHUMP_REPO=' -e '^CHUMP_REPO =' \
        -e '^CHUMP_HOME=' -e '^CHUMP_HOME =' \
        -e '^CHUMP_WARM_SERVERS=' -e '^CHUMP_WARM_SERVERS =' \
        -e '^CHUMP_CURSOR_CLI=' -e '^CHUMP_CURSOR_CLI =' \
        -e '^CHUMP_PROJECT_MODE=' -e '^CHUMP_PROJECT_MODE =' \
        -e '^CHUMP_SYSTEM_PROMPT=' -e '^CHUMP_SYSTEM_PROMPT =' \
        "$ENV_FILE" > "$TMP_ENV" 2>/dev/null || true
mv "$TMP_ENV" "$ENV_FILE"

# Append badass soul (value with spaces in double quotes; inner " escaped)
printf 'CHUMP_SYSTEM_PROMPT="%s"\n' "$(echo "$BADASS_SOUL" | sed 's/"/\\"/g')" >> "$ENV_FILE"

echo "Updated $ENV_FILE: stripped bloat vars, set CHUMP_SYSTEM_PROMPT to badass soul."

# Restart bot only (leave llama-server running)
if pgrep -f 'chump --discord' >/dev/null 2>&1; then
  echo "Restarting Discord bot..."
  pkill -f 'chump --discord' || true
  sleep 2
fi
cd "$CHUMP_DIR" && nohup ./start-companion.sh --bot >> "$CHUMP_DIR/logs/companion.log" 2>&1 &
echo "Bot started. Check: tail -f $CHUMP_DIR/logs/companion.log"
