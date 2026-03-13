#!/usr/bin/env bash
# Build Chump for Android, push to Pixel (Termux), and restart the Mabel bot.
# Uses chump.new then mv so we can replace the binary while the bot is stopped.
#
# Usage: ./scripts/deploy-mabel-to-pixel.sh [ssh_host]
#   ssh_host: default termux (from ~/.ssh/config). Must have ~/chump and start-companion.sh.
#
# Run from Chump repo root. Requires Android NDK for build; SSH key for termux.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SSH_HOST="${1:-termux}"
PORT="${DEPLOY_PORT:-8022}"
BINARY="$REPO_ROOT/target/aarch64-linux-android/release/rust-agent"

cd "$REPO_ROOT"
echo "==> Building for aarch64-linux-android..."
./scripts/build-android.sh
[[ -f "$BINARY" ]] || { echo "Build failed or binary missing."; exit 1; }

echo ""
echo "==> Stopping bot on $SSH_HOST..."
ssh -p "$PORT" "$SSH_HOST" 'pkill -f "chump --discord" 2>/dev/null || true; pkill -f "start-companion" 2>/dev/null || true; sleep 2' || true

echo "==> Uploading binary (as chump.new)..."
scp -P "$PORT" "$BINARY" "$SSH_HOST:~/chump/chump.new"
if [[ -f "$SCRIPT_DIR/start-companion.sh" ]]; then
  scp -P "$PORT" "$SCRIPT_DIR/start-companion.sh" "$SSH_HOST:~/chump/start-companion.sh"
  ssh -p "$PORT" "$SSH_HOST" "chmod +x ~/chump/start-companion.sh"
fi

echo "==> Replacing binary and starting bot..."
ssh -p "$PORT" "$SSH_HOST" 'mv -f ~/chump/chump.new ~/chump/chump && chmod +x ~/chump/chump && cd ~/chump && nohup ./start-companion.sh --bot >> ~/chump/logs/companion.log 2>&1 </dev/null &>/dev/null & sleep 3; tail -4 ~/chump/logs/companion.log'

echo ""
echo "Done. Mabel (bot) restarted on $SSH_HOST. Send a Discord message and check: ssh -p $PORT $SSH_HOST 'grep \"[timing]\" ~/chump/logs/companion.log | tail -5'"
