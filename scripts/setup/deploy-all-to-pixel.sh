#!/usr/bin/env bash
# Single command: build Chump for Android, push binary + scripts to Pixel, apply Mabel env, restart.
# Use this to move fast — one script for "deploy everything to Mabel on Pixel".
# Bulletproof: deploy-mabel and script push use retries and robust SSH/SCP options.
#
# Usage: ./scripts/setup/deploy-all-to-pixel.sh [ssh_host]
#   ssh_host: default termux. Env: PIXEL_SSH_HOST, PIXEL_SSH_PORT (or DEPLOY_PORT) override when set (e.g. after source .env).
#   Must have ~/chump and start-companion.sh on the target.
#
# IMPORTANT: Run from a real terminal (not a short-lived runner). The Android build can take
# 5–10 minutes; if the process is killed (e.g. by a timeout), the deploy will fail.
#
# Does: build Android binary → stop bot → upload binary + start-companion.sh + apply-mabel-badass-env.sh
#       → replace binary & start bot → run apply-mabel-badass-env.sh (refresh .env: soul, CHUMP_MABEL=1, restart).
#
# Run from Chump repo root. Requires Android NDK for build; SSH key for termux.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# Use PIXEL_SSH_HOST / PIXEL_SSH_PORT from env when set (e.g. after source .env); else arg and DEPLOY_PORT.
SSH_HOST="${PIXEL_SSH_HOST:-${1:-termux}}"
PORT="${PIXEL_SSH_PORT:-${DEPLOY_PORT:-8022}}"
MAX_ATTEMPTS="${DEPLOY_ALL_SSH_MAX_ATTEMPTS:-3}"
RETRY_SLEEP="${DEPLOY_RETRY_SLEEP:-5}"

SSH_OPTS=(-o ConnectTimeout=20 -o ServerAliveInterval=5 -o ServerAliveCountMax=24 -o BatchMode=yes -p "$PORT")
SCP_OPTS=(-o ConnectTimeout=20 -o ServerAliveInterval=5 -o BatchMode=yes -P "$PORT")

cd "$REPO_ROOT"

echo "==> Deploy all to Pixel ($SSH_HOST): build, push binary + scripts, apply env, restart"
echo "    (Build can take 5–10 min; run from a terminal to avoid timeout.)"
echo ""

# 1) Build and deploy binary (stops bot, uploads binary + start-companion.sh, replaces binary, starts bot)
./scripts/setup/deploy-mabel-to-pixel.sh "$SSH_HOST"

# 2) Push scripts and run apply-mabel-badass-env (with retries)
echo ""
echo "==> Pushing scripts and applying Mabel env on $SSH_HOST..."
attempt=1
while [[ $attempt -le $MAX_ATTEMPTS ]]; do
  if [[ $attempt -gt 1 ]]; then echo "Retry $attempt/$MAX_ATTEMPTS in ${RETRY_SLEEP}s..."; sleep "$RETRY_SLEEP"; fi
  if scp "${SCP_OPTS[@]}" "$SCRIPT_DIR/apply-mabel-badass-env.sh" "$SSH_HOST:~/chump/apply-mabel-badass-env.sh" 2>/dev/null \
     && ssh "${SSH_OPTS[@]}" "$SSH_HOST" "mkdir -p ~/chump/scripts" 2>/dev/null; then
    break
  fi
  attempt=$((attempt + 1))
done
[[ $attempt -le $MAX_ATTEMPTS ]] || { echo "ERROR: Failed to push apply script after $MAX_ATTEMPTS attempts."; exit 1; }

for f in mabel-farmer.sh heartbeat-mabel.sh restart-mabel-heartbeat.sh screen-ocr.sh switch-mabel-to-qwen3-4b.sh ensure-mabel-bot-up.sh; do
  [[ -f "$SCRIPT_DIR/$f" ]] && scp "${SCP_OPTS[@]}" "$SCRIPT_DIR/$f" "$SSH_HOST:~/chump/scripts/$f" 2>/dev/null || true
done

# Option A: supply Mac cascade keys so apply-mabel-badass-env (run on Pixel) can inject them.
# On the Pixel, MAC_ENV defaults to $HOME/Projects/Chump/.env which does not exist; without this, Mabel gets no cascade.
MAC_ENV_REMOTE=""
if [[ -f "$REPO_ROOT/.env" ]]; then
  TMP_ENV_MAC=$(mktemp)
  trap 'rm -f "$TMP_ENV_MAC"' EXIT
  grep -E '^CHUMP_PROVIDER_(1|2)_KEY=' "$REPO_ROOT/.env" > "$TMP_ENV_MAC" 2>/dev/null || true
  if [[ -s "$TMP_ENV_MAC" ]]; then
    attempt=1
    while [[ $attempt -le $MAX_ATTEMPTS ]]; do
      if [[ $attempt -gt 1 ]]; then echo "SCP .env.mac retry $attempt/$MAX_ATTEMPTS..."; sleep "$RETRY_SLEEP"; fi
      if scp "${SCP_OPTS[@]}" "$TMP_ENV_MAC" "$SSH_HOST:~/chump/.env.mac" 2>/dev/null; then
        MAC_ENV_REMOTE="\$HOME/chump/.env.mac"
        echo "  Pushed Mac cascade keys to $SSH_HOST:~/chump/.env.mac"
        break
      fi
      attempt=$((attempt + 1))
    done
  fi
  rm -f "$TMP_ENV_MAC"
  trap - EXIT
fi

apply_cmd="chmod +x ~/chump/apply-mabel-badass-env.sh; for x in ~/chump/scripts/*.sh; do chmod +x \"\$x\" 2>/dev/null; done"
if [[ -n "$MAC_ENV_REMOTE" ]]; then
  apply_cmd="$apply_cmd; MAC_ENV=$MAC_ENV_REMOTE bash ~/chump/apply-mabel-badass-env.sh"
else
  apply_cmd="$apply_cmd; bash ~/chump/apply-mabel-badass-env.sh"
fi

attempt=1
while [[ $attempt -le $MAX_ATTEMPTS ]]; do
  if [[ $attempt -gt 1 ]]; then echo "Apply env retry $attempt/$MAX_ATTEMPTS in ${RETRY_SLEEP}s..."; sleep "$RETRY_SLEEP"; fi
  if ssh "${SSH_OPTS[@]}" "$SSH_HOST" "$apply_cmd" 2>/dev/null; then
    echo ""
    echo "Done. Mabel on $SSH_HOST: latest binary, soul, CHUMP_MABEL=1, bot restarted."
    echo "Check: ssh $SSH_HOST 'tail -6 ~/chump/logs/companion.log'"
    exit 0
  fi
  attempt=$((attempt + 1))
done
echo "ERROR: apply-mabel-badass-env failed after $MAX_ATTEMPTS attempts."
exit 1
