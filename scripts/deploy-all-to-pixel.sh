#!/usr/bin/env bash
# Single command: build Chump for Android, push binary + scripts to Pixel, apply Mabel env, restart.
# Use this to move fast — one script for "deploy everything to Mabel on Pixel".
#
# Usage: ./scripts/deploy-all-to-pixel.sh [ssh_host]
#   ssh_host: default termux (from ~/.ssh/config). Must have ~/chump and start-companion.sh.
#
# Does: build Android binary → stop bot → upload binary + start-companion.sh + apply-mabel-badass-env.sh
#       → replace binary & start bot → run apply-mabel-badass-env.sh (refresh .env: soul, CHUMP_MABEL=1, restart).
#
# Run from Chump repo root. Requires Android NDK for build; SSH key for termux.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SSH_HOST="${1:-termux}"
PORT="${DEPLOY_PORT:-8022}"

cd "$REPO_ROOT"

echo "==> Deploy all to Pixel ($SSH_HOST): build, push binary + scripts, apply env, restart"
echo ""

# 1) Build and deploy binary (stops bot, uploads binary + start-companion.sh, replaces binary, starts bot)
./scripts/deploy-mabel-to-pixel.sh "$SSH_HOST"

# 2) Push scripts used on Pixel (apply env, mabel-farmer, heartbeat-mabel)
echo ""
echo "==> Pushing scripts (apply-mabel-badass-env.sh, mabel-farmer.sh, heartbeat-mabel.sh) to $SSH_HOST..."
scp -P "$PORT" "$SCRIPT_DIR/apply-mabel-badass-env.sh" "$SSH_HOST:~/chump/apply-mabel-badass-env.sh"
ssh -p "$PORT" "$SSH_HOST" "mkdir -p ~/chump/scripts"
scp -P "$PORT" "$SCRIPT_DIR/mabel-farmer.sh" "$SSH_HOST:~/chump/scripts/mabel-farmer.sh" 2>/dev/null || true
scp -P "$PORT" "$SCRIPT_DIR/heartbeat-mabel.sh" "$SSH_HOST:~/chump/scripts/heartbeat-mabel.sh" 2>/dev/null || true
ssh -p "$PORT" "$SSH_HOST" "chmod +x ~/chump/apply-mabel-badass-env.sh; [ -f ~/chump/scripts/mabel-farmer.sh ] && chmod +x ~/chump/scripts/mabel-farmer.sh; [ -f ~/chump/scripts/heartbeat-mabel.sh ] && chmod +x ~/chump/scripts/heartbeat-mabel.sh; bash ~/chump/apply-mabel-badass-env.sh"

echo ""
echo "Done. Mabel on $SSH_HOST: latest binary, soul, CHUMP_MABEL=1, bot restarted."
echo "Check: ssh $SSH_HOST 'tail -6 ~/chump/logs/companion.log'"
