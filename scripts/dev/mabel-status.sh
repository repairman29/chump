#!/usr/bin/env bash
# Check Mabel status on the Pixel: bot process and Pixel's local model (llama-server).
# Run from the Mac. Uses same SSH/ADB setup as restart-mabel-bot-on-pixel.sh.
# Output: "Mabel: online" or "Mabel: bot not running"; "Pixel model (llama-server :PORT): up" or "down (HTTP CODE)".
#
# Usage: ./scripts/dev/mabel-status.sh
# Env: PIXEL_SSH_HOST, PIXEL_SSH_PORT (8022), PIXEL_MODEL_PORT (Pixel's llama-server port; default 8000), PIXEL_USE_ADB.

set -e
ROOT="${CHUMP_HOME:-$(cd "$(dirname "$0")/.." && pwd)}"
cd "$ROOT"
[[ -f .env ]] && set -a && source .env && set +a

SSH_PORT="${PIXEL_SSH_PORT:-8022}"
PIXEL_MODEL_PORT="${PIXEL_MODEL_PORT:-8000}"

USE_ADB=
if command -v adb &>/dev/null; then
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
  adb forward tcp:"$SSH_PORT" tcp:"$SSH_PORT" 2>/dev/null || true
  SSH_HOST="127.0.0.1"
  SSH_USER=$(ssh -G termux 2>/dev/null | awk '/^user /{print $2}' || true)
  TERMUX_IDENTITY=$(ssh -G termux 2>/dev/null | awk '/^identityfile /{print $2; exit}')
  [[ -n "$TERMUX_IDENTITY" ]] && TERMUX_IDENTITY="${TERMUX_IDENTITY/#\~/$HOME}"
  for _ in 1 2 3 4 5; do
    ssh-keygen -R "[127.0.0.1]:$SSH_PORT" -f "$HOME/.ssh/known_hosts" 2>/dev/null || break
  done
  SSH_OPTS_ADB=( -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null )
else
  SSH_HOST="${PIXEL_SSH_HOST:-termux}"
  TERMUX_IDENTITY=
  SSH_OPTS_ADB=()
fi

SSH_OPTS=(
  -o ConnectTimeout=8
  -o BatchMode=yes
  -p "$SSH_PORT"
  "${SSH_OPTS_ADB[@]}"
)
[[ -n "${SSH_USER:-}" ]] && SSH_OPTS+=( -o "User=$SSH_USER" )
[[ -n "${TERMUX_IDENTITY:-}" ]] && [[ -f "$TERMUX_IDENTITY" ]] && SSH_OPTS+=( -o "IdentityFile=$TERMUX_IDENTITY" )

OUT=$(ssh "${SSH_OPTS[@]}" "$SSH_HOST" "pgrep -f 'chump.*--discord' 2>/dev/null | wc -l; curl -s -o /dev/null -w '%{http_code}' --max-time 3 http://127.0.0.1:${PIXEL_MODEL_PORT}/v1/models 2>/dev/null || echo '000'" 2>/dev/null) || true
if [[ -z "$OUT" ]]; then
  echo "Mabel: unreachable (SSH to Pixel failed)."
  exit 1
fi

BOT_COUNT=$(echo "$OUT" | head -1)
CURL_CODE=$(echo "$OUT" | tail -1)

if [[ "${BOT_COUNT:-0}" -gt 0 ]]; then
  echo "Mabel: online"
else
  echo "Mabel: bot not running"
fi

if [[ "$CURL_CODE" == "200" ]]; then
  echo "Pixel model (llama-server :$PIXEL_MODEL_PORT): up."
else
  echo "Pixel model (llama-server :$PIXEL_MODEL_PORT): down (HTTP ${CURL_CODE:-?})."
fi
