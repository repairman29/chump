#!/usr/bin/env bash
# One-shot "I'm using Chump today": ensure web is up, then open the PWA in your browser.
# Use from Terminal, a macOS Shortcut (Run Shell Script), or Login Items *after* ChumpMenu if you prefer menu-bar control.
#
# Prerequisites: repo `.env` + inference per docs/operations/INFERENCE_PROFILES.md (Ollama, vLLM-MLX, or mistral.rs).
#
# Env (optional):
#   CHUMP_HOME / CHUMP_REPO  — repo root (default: parent of scripts/)
#   CHUMP_WEB_PORT           — default 3000
#   CHUMP_OPEN_MENU=1        — also open ChumpMenu.app if found (Applications or ChumpMenu/ChumpMenu.app)

set -e
ROOT="${CHUMP_HOME:-$(cd "$(dirname "$0")/../.." && pwd)}"
cd "$ROOT"
export CHUMP_HOME="$ROOT"
export CHUMP_REPO="${CHUMP_REPO:-$ROOT}"

if [[ -f .env ]]; then
  set -a
  # shellcheck disable=SC1091
  source .env
  set +a
fi

PORT="${CHUMP_WEB_PORT:-3000}"
HOST="${CHUMP_WEB_HOST:-127.0.0.1}"
BASE="http://${HOST}:${PORT}"

health_ok() {
  local h
  h="$(curl -s --max-time 2 "${BASE}/api/health" 2>/dev/null || true)"
  [[ "$h" == *chump-web* ]]
}

open_menu() {
  [[ "${CHUMP_OPEN_MENU:-0}" == "1" ]] || return 0
  if [[ -d "/Applications/ChumpMenu.app" ]]; then
    open -a ChumpMenu
  elif [[ -d "$ROOT/ChumpMenu/ChumpMenu.app" ]]; then
    open "$ROOT/ChumpMenu/ChumpMenu.app"
  fi
}

if health_ok; then
  echo "Chump web already up — opening ${BASE}"
  open "${BASE}/" 2>/dev/null || true
  open_menu
  exit 0
fi

mkdir -p logs
echo "Starting Chump web (./run-web.sh)…"
nohup ./run-web.sh --port "$PORT" >>"$ROOT/logs/chump-web.log" 2>&1 &
disown || true

for i in $(seq 1 60); do
  if health_ok; then
    echo "Ready — opening ${BASE}"
    open "${BASE}/" 2>/dev/null || true
    open_menu
    exit 0
  fi
  sleep 1
done

echo "Timed out waiting for ${BASE}/api/health. Check logs/chump-web.log and inference (Ollama / MLX / .env)."
exit 1
