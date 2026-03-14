#!/usr/bin/env bash
# Build Chump for Android, push to Pixel (Termux), and restart the Mabel bot.
# Uses chump.new then mv so we can replace the binary while the bot is stopped.
# Bulletproof: retries for SCP and final SSH; robust timeouts and keepalives.
#
# Usage: ./scripts/deploy-mabel-to-pixel.sh [ssh_host]
#   ssh_host: default termux (from ~/.ssh/config). Must have ~/chump and start-companion.sh.
#
# Run from Chump repo root. Requires Android NDK for build; SSH key for termux.
# For long builds (5–10 min), run from a terminal so the process isn't killed by timeouts.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SSH_HOST="${1:-termux}"
PORT="${DEPLOY_PORT:-8022}"
BINARY="$REPO_ROOT/target/aarch64-linux-android/release/rust-agent"
MAX_SCP_ATTEMPTS="${DEPLOY_SCP_MAX_ATTEMPTS:-3}"
MAX_SSH_ATTEMPTS="${DEPLOY_SSH_MAX_ATTEMPTS:-3}"
RETRY_SLEEP="${DEPLOY_RETRY_SLEEP:-5}"

# Robust SSH/SCP: keepalives and longer timeouts so uploads and remote commands don't drop
SSH_OPTS=(-o ConnectTimeout=20 -o ServerAliveInterval=5 -o ServerAliveCountMax=24 -o BatchMode=yes -p "$PORT")
SCP_OPTS=(-o ConnectTimeout=20 -o ServerAliveInterval=5 -o BatchMode=yes -P "$PORT")

cd "$REPO_ROOT"
echo "==> Building for aarch64-linux-android..."
./scripts/build-android.sh
[[ -f "$BINARY" ]] || { echo "Build failed or binary missing."; exit 1; }

echo ""
echo "==> Stopping bot on $SSH_HOST..."
ssh "${SSH_OPTS[@]}" "$SSH_HOST" 'pkill -f "chump --discord" 2>/dev/null || true; pkill -f "start-companion" 2>/dev/null || true; sleep 2' || true

echo "==> Uploading binary (as chump.new)..."
attempt=1
while [[ $attempt -le $MAX_SCP_ATTEMPTS ]]; do
  if [[ $attempt -gt 1 ]]; then echo "SCP retry $attempt/$MAX_SCP_ATTEMPTS in ${RETRY_SLEEP}s..."; sleep "$RETRY_SLEEP"; fi
  if scp "${SCP_OPTS[@]}" "$BINARY" "$SSH_HOST:~/chump/chump.new" 2>/dev/null; then
    break
  fi
  attempt=$((attempt + 1))
done
if [[ $attempt -gt $MAX_SCP_ATTEMPTS ]]; then
  echo "ERROR: Upload failed after $MAX_SCP_ATTEMPTS attempts."
  exit 1
fi

if [[ -f "$SCRIPT_DIR/start-companion.sh" ]]; then
  scp "${SCP_OPTS[@]}" "$SCRIPT_DIR/start-companion.sh" "$SSH_HOST:~/chump/start-companion.sh" 2>/dev/null || true
  ssh "${SSH_OPTS[@]}" "$SSH_HOST" "chmod +x ~/chump/start-companion.sh" 2>/dev/null || true
fi

echo "==> Replacing binary and starting bot..."
attempt=1
while [[ $attempt -le $MAX_SSH_ATTEMPTS ]]; do
  if [[ $attempt -gt 1 ]]; then echo "SSH retry $attempt/$MAX_SSH_ATTEMPTS in ${RETRY_SLEEP}s..."; sleep "$RETRY_SLEEP"; fi
  if ssh "${SSH_OPTS[@]}" "$SSH_HOST" 'mv -f ~/chump/chump.new ~/chump/chump && chmod +x ~/chump/chump && cd ~/chump && nohup ./start-companion.sh --bot >> ~/chump/logs/companion.log 2>&1 </dev/null &>/dev/null & sleep 3; tail -4 ~/chump/logs/companion.log' 2>/dev/null; then
    echo ""
    echo "Done. Mabel (bot) restarted on $SSH_HOST. Send a Discord message and check: ssh -p $PORT $SSH_HOST 'grep \"[timing]\" ~/chump/logs/companion.log | tail -5'"
    exit 0
  fi
  attempt=$((attempt + 1))
done
echo "ERROR: Replace/start failed after $MAX_SSH_ATTEMPTS attempts."
exit 1
