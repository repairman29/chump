#!/usr/bin/env bash
# Self-reboot: kill current Discord bot, rebuild release, start new one.
# Run from Chump repo root or set CHUMP_HOME. Logs to logs/self-reboot.log when invoked as:
#   nohup bash scripts/self-reboot.sh >> logs/self-reboot.log 2>&1 &
# The bot invokes this via run_cli; after DELAY seconds the bot is killed and the script continues (nohup), rebuilds, and starts the new bot.
set -e
ROOT="${CHUMP_HOME:-$(cd "$(dirname "$0")/.." && pwd)}"
cd "$ROOT"
DELAY="${CHUMP_SELF_REBOOT_DELAY:-10}"
mkdir -p logs
echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] self-reboot: waiting ${DELAY}s then killing Discord bot..."
sleep "$DELAY"
echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] self-reboot: killing rust-agent --discord"
pkill -f "rust-agent.*--discord" || true
sleep 2
echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] self-reboot: building release..."
cargo build --release
echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] self-reboot: starting new bot"
nohup ./run-discord.sh >> logs/discord.log 2>&1 &
echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] self-reboot: done"
