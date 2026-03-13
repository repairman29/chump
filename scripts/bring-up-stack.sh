#!/usr/bin/env bash
# Bring up the whole Chump stack: roles (launchd), Ollama, optional Discord, and heartbeats.
# Use after a fresh clone, reboot, or when you want everything running. Optionally pull and build first.
#
# Usage:
#   ./scripts/bring-up-stack.sh                    # start stack (no pull/build)
#   PULL=1 ./scripts/bring-up-stack.sh             # git pull, then build and start
#   BUILD_ONLY=1 ./scripts/bring-up-stack.sh        # only build release; don't start processes
#
# Env (from .env or here):
#   PULL=1           Run git pull --rebase before building (default 0).
#   BUILD_ONLY=1     Only cargo build --release; skip starting anything (default 0).
#   ROLES=1          Install and load launchd roles (default 1). Set 0 to skip.
#   KEEPALIVE=1      Run keep-chump-online once: Ollama, optional embed, optional Discord (default 1).
#   HEARTBEATS=1     Start self-improve and cursor-improve heartbeats in background (default 1).
#   CHUMP_KEEPALIVE_DISCORD=1  If set with KEEPALIVE=1, keep-chump-online will start Discord.
#   CHUMP_KEEPALIVE_EMBED=1    If set with KEEPALIVE=1, keep-chump-online will start embed server.
#
# Logs: logs/*.log. Roles run on schedule via launchd; heartbeats run in background until duration expires.

set -e
ROOT="${CHUMP_HOME:-$(cd "$(dirname "$0")/.." && pwd)}"
cd "$ROOT"
export PATH="${HOME}/.local/bin:${HOME}/.cursor/bin:${PATH}"
if [[ -f .env ]]; then
  set -a
  source .env
  set +a
fi

PULL="${PULL:-0}"
BUILD_ONLY="${BUILD_ONLY:-0}"
ROLES="${ROLES:-1}"
KEEPALIVE="${KEEPALIVE:-1}"
HEARTBEATS="${HEARTBEATS:-1}"

mkdir -p "$ROOT/logs"

echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] bring-up-stack: starting (PULL=$PULL BUILD_ONLY=$BUILD_ONLY ROLES=$ROLES KEEPALIVE=$KEEPALIVE HEARTBEATS=$HEARTBEATS)"

if [[ "$PULL" == "1" ]]; then
  echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] bring-up-stack: git pull --rebase"
  git pull --rebase || true
fi

echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] bring-up-stack: cargo build --release"
cargo build --release

if [[ "$BUILD_ONLY" == "1" ]]; then
  echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] bring-up-stack: BUILD_ONLY=1, done."
  exit 0
fi

if [[ "$ROLES" == "1" ]] && [[ -x "$ROOT/scripts/install-roles-launchd.sh" ]]; then
  echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] bring-up-stack: installing and loading launchd roles"
  "$ROOT/scripts/install-roles-launchd.sh" || true
else
  echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] bring-up-stack: skipping roles (ROLES=$ROLES)"
fi

if [[ "$KEEPALIVE" == "1" ]] && [[ -x "$ROOT/scripts/keep-chump-online.sh" ]]; then
  echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] bring-up-stack: running keep-chump-online (Ollama, optional embed/Discord)"
  "$ROOT/scripts/keep-chump-online.sh" || true
else
  echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] bring-up-stack: skipping keep-chump-online (KEEPALIVE=$KEEPALIVE)"
fi

if [[ "$HEARTBEATS" == "1" ]]; then
  echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] bring-up-stack: starting heartbeats"
  # Max mode (8000): ensure heartbeats use vLLM-MLX env
  if [[ "${OPENAI_API_BASE:-}" == *":8000"* ]] && [[ -f "$ROOT/scripts/env-max_m4.sh" ]]; then
    source "$ROOT/scripts/env-max_m4.sh"
    echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] bring-up-stack: using max_m4 env (8000/14B)"
  fi
  pkill -f heartbeat-self-improve 2>/dev/null || true
  pkill -f heartbeat-cursor-improve-loop 2>/dev/null || true
  sleep 1
  nohup bash "$ROOT/scripts/heartbeat-self-improve.sh" >> "$ROOT/logs/heartbeat-self-improve.log" 2>&1 &
  echo "  self-improve PID: $!"
  nohup bash "$ROOT/scripts/heartbeat-cursor-improve-loop.sh" >> "$ROOT/logs/heartbeat-cursor-improve-loop.log" 2>&1 &
  echo "  cursor-improve PID: $!"
else
  echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] bring-up-stack: skipping heartbeats (HEARTBEATS=$HEARTBEATS)"
fi

echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] bring-up-stack: done. Roles run on schedule (launchd). Heartbeats in background. Logs: $ROOT/logs/*.log"
