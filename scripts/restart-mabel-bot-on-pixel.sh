#!/usr/bin/env bash
# Restart Mabel's Discord bot on the Pixel. Use from the Mac when Mabel's chat
# is stuck (e.g. "circuit open for 30s") or the bot died. Clears in-memory circuit state.
#
# When the Pixel is on USB: uses ADB to forward port 8022, then SSH over USB (no WiFi).
# Otherwise: SSH to PIXEL_SSH_HOST (e.g. termux over Tailscale/WiFi). Two short SSHs + retries.
#
# Usage: ./scripts/restart-mabel-bot-on-pixel.sh
# Env: PIXEL_SSH_HOST (default termux), PIXEL_SSH_PORT (8022), PIXEL_MODEL_PORT (Pixel's llama-server port; same as CHUMP_PORT in ~/chump/.env on the Pixel; default 8000; set to e.g. 8001 if Pixel uses CHUMP_PORT=8001 so 8000 is Mac-only). PIXEL_USE_ADB=1 to force ADB path. PIXEL_SSH_FORCE_NETWORK=1 to use Tailscale/WiFi SSH instead of ADB.
# Mabel runs on the Pixel and uses the Pixel's local model (llama-server). Every model check in this script runs on the device via SSH; we never probe the Mac's 8000.

set -e
ROOT="${CHUMP_HOME:-$(cd "$(dirname "$0")/.." && pwd)}"
cd "$ROOT"
if [[ -f .env ]]; then
  set -a
  source .env
  set +a
fi

SSH_PORT="${PIXEL_SSH_PORT:-8022}"
PIXEL_MODEL_PORT="${PIXEL_MODEL_PORT:-8000}"
MAX_ATTEMPTS="${RESTART_MABEL_MAX_ATTEMPTS:-3}"
RETRY_SLEEP="${RESTART_MABEL_RETRY_SLEEP:-5}"

# Prefer ADB when device is on USB: one device in adb devices (or CHUMP_ADB_DEVICE set).
# Set PIXEL_SSH_FORCE_NETWORK=1 to use Tailscale/WiFi SSH instead (e.g. Pixel in office, no USB).
USE_ADB=
if [[ -n "${PIXEL_SSH_FORCE_NETWORK:-}" ]] && [[ "$PIXEL_SSH_FORCE_NETWORK" =~ ^1|yes|true$ ]]; then
  USE_ADB=
elif command -v adb &>/dev/null; then
  if [[ -n "${PIXEL_USE_ADB:-}" ]] && [[ "$PIXEL_USE_ADB" =~ ^1|yes|true$ ]]; then
    USE_ADB=1
  elif [[ -n "${CHUMP_ADB_DEVICE:-}" ]]; then
    USE_ADB=1
  else
    N=$(adb devices 2>/dev/null | grep -c 'device$' || true)
    [[ "$N" -eq 1 ]] && USE_ADB=1
  fi
fi

if [[ -n "$USE_ADB" ]]; then
  echo "Pixel on USB: using ADB forward so SSH goes over the cable."
  adb forward tcp:"$SSH_PORT" tcp:"$SSH_PORT" 2>/dev/null || true
  SSH_HOST="127.0.0.1"
  SSH_USER=$(ssh -G termux 2>/dev/null | awk '/^user /{print $2}' || true)
  TERMUX_IDENTITY=$(ssh -G termux 2>/dev/null | awk '/^identityfile /{print $2; exit}')
  [[ -n "$TERMUX_IDENTITY" ]] && TERMUX_IDENTITY="${TERMUX_IDENTITY/#\~/$HOME}"
  # Remove stale keys for [127.0.0.1]:port (max 5 runs in case of duplicates)
  for _ in 1 2 3 4 5; do
    ssh-keygen -R "[127.0.0.1]:$SSH_PORT" -f "$HOME/.ssh/known_hosts" 2>/dev/null || break
  done
  # Over USB we connect to our own forwarded port — skip host key check so key churn never blocks
  SSH_OPTS_ADB=( -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null )
else
  SSH_HOST="${PIXEL_SSH_HOST:-termux}"
  TERMUX_IDENTITY=
  SSH_OPTS_ADB=()
fi

SSH_OPTS=(
  -o ConnectTimeout=10
  -o ServerAliveInterval=5
  -o ServerAliveCountMax=12
  -o BatchMode=yes
  -p "$SSH_PORT"
  "${SSH_OPTS_ADB[@]}"
)
[[ -n "${SSH_USER:-}" ]] && SSH_OPTS+=( -o "User=$SSH_USER" )
[[ -n "${TERMUX_IDENTITY:-}" ]] && [[ -f "$TERMUX_IDENTITY" ]] && SSH_OPTS+=( -o "IdentityFile=$TERMUX_IDENTITY" )

# TCP check when over USB (so we know if port isn't open vs SSH auth failure)
if [[ -n "$USE_ADB" ]] && command -v nc &>/dev/null; then
  if ! nc -z -w 2 127.0.0.1 "$SSH_PORT" 2>/dev/null; then
    echo "ERROR: Port $SSH_PORT not reachable after adb forward. Termux must be running with sshd."
    echo "On the Pixel: open the Termux app, then run: sshd"
    echo "Then run this script again."
    exit 1
  fi
fi

# Quick probe
PROBE_ERR=$(mktemp 2>/dev/null || echo "/tmp/probe_$$")
ssh "${SSH_OPTS[@]}" "$SSH_HOST" 'echo ok' 2>"$PROBE_ERR" | grep -q '^ok' || true
PROBE_OK=$?
if [[ $PROBE_OK -ne 0 ]]; then
  echo "ERROR: Cannot reach Pixel (SSH to ${SSH_USER:+$SSH_USER@}$SSH_HOST:$SSH_PORT failed)."
  if [[ -s "$PROBE_ERR" ]]; then
    echo "SSH said: $(cat "$PROBE_ERR" | head -5)"
  fi
  [[ -f "$PROBE_ERR" ]] && rm -f "$PROBE_ERR"
  if [[ -n "$USE_ADB" ]]; then
    echo ""
    echo "With USB: (1) Open the Termux app on the Pixel so it's running. (2) In Termux run: sshd"
    echo "Then: adb forward tcp:$SSH_PORT tcp:$SSH_PORT && ssh -p $SSH_PORT -o StrictHostKeyChecking=no ${SSH_USER:+$SSH_USER@}127.0.0.1 'echo ok'"
  else
    echo "Check: PIXEL_SSH_HOST=$SSH_HOST, PIXEL_SSH_PORT=$SSH_PORT, network, Termux/sshd on Pixel."
  fi
  exit 1
fi
[[ -f "$PROBE_ERR" ]] && rm -f "$PROBE_ERR"

echo "Restarting Mabel Discord bot on Pixel ($SSH_HOST:$SSH_PORT) (up to ${MAX_ATTEMPTS} attempts)..."

attempt=1
while [[ $attempt -le $MAX_ATTEMPTS ]]; do
  if [[ $attempt -gt 1 ]]; then
    echo "Retry $attempt/$MAX_ATTEMPTS in ${RETRY_SLEEP}s..."
    sleep "$RETRY_SLEEP"
  fi

  # One SSH: run restart script from stdin so the command line is short (bash -s). Reduces 255 on Termux.
  set +e
  ssh "${SSH_OPTS[@]}" "$SSH_HOST" 'bash -s' << 'REMOTE_SCRIPT'
cd ~/chump || exit 1
pkill -f "chump.*--discord" 2>/dev/null || true
sleep 2
nohup ./start-companion.sh --bot >> logs/companion.log 2>&1 </dev/null &
sleep 3
exit 0
REMOTE_SCRIPT
  E1=$?
  set -e
  if [[ $E1 -ne 0 ]]; then
    echo "Attempt $attempt failed: restart SSH exited $E1."
    attempt=$((attempt + 1))
    continue
  fi

  sleep 5

  set +e
  REMOTE_OUT=$(ssh "${SSH_OPTS[@]}" "$SSH_HOST" "pgrep -f 'chump.*--discord' 2>/dev/null | wc -l; curl -s -o /dev/null -w '%{http_code}' --max-time 5 http://127.0.0.1:${PIXEL_MODEL_PORT}/v1/models 2>/dev/null || echo '000'")
  E2=$?
  set -e
  if [[ $E2 -ne 0 ]] || [[ -z "$REMOTE_OUT" ]]; then
    echo "Attempt $attempt failed: second SSH exited $E2 (bot may still have started)."
    attempt=$((attempt + 1))
    continue
  fi

  PGREP_COUNT=$(echo "$REMOTE_OUT" | head -1)
  CURL_CODE=$(echo "$REMOTE_OUT" | tail -1)
  if [[ "$PGREP_COUNT" -gt 0 ]]; then
    echo "Mabel bot started."
  else
    echo "Bot may still be starting or failed. Check ~/chump/logs/companion.log on Pixel."
  fi
  if [[ "$CURL_CODE" == "200" ]]; then
    echo "Pixel model (llama-server :$PIXEL_MODEL_PORT): up."
  else
    echo "Warn: Pixel model (llama-server :$PIXEL_MODEL_PORT) returned HTTP $CURL_CODE. Set CHUMP_PORT=$PIXEL_MODEL_PORT and CHUMP_MODEL_REQUEST_TIMEOUT_SECS=420 in ~/chump/.env on the Pixel; ensure llama-server is up there."
  fi
  echo "Done."
  exit 0
done

echo "ERROR: Restart failed after ${MAX_ATTEMPTS} attempts."
echo ""
echo "On the Pixel (Termux), run:"
echo "  pkill -f 'chump.*--discord'; sleep 2; cd ~/chump && ./start-companion.sh --bot"
echo ""
if [[ -n "$USE_ADB" ]]; then
  echo "From Mac (SSH over USB): ssh -p $SSH_PORT ${SSH_USER:+$SSH_USER@}127.0.0.1 'echo ok'"
else
  echo "From Mac: ssh -p $SSH_PORT $SSH_HOST 'echo ok'"
fi
exit 1
