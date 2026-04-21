#!/usr/bin/env bash
# Deploy the Mac bot: build release binary, hot-swap Discord + Web processes.
# Safer than self-reboot.sh: waits for any in-progress cargo build lock before killing
# the bot, so you never race a background Android build against the Mac rebuild.
#
# Usage:
#   ./scripts/deploy-mac.sh           # build + restart Discord + Web
#   ./scripts/deploy-mac.sh --discord # restart Discord bot only
#   ./scripts/deploy-mac.sh --web     # restart Web bot only
#   ./scripts/deploy-mac.sh --build-only  # just build; don't restart anything
#
# Env overrides:
#   DEPLOY_MAC_TIMEOUT=600  max seconds to wait for the build lock (default 600)

set -euo pipefail
ROOT="${CHUMP_HOME:-$(cd "$(dirname "$0")/.." && pwd)}"
cd "$ROOT"

RESTART_DISCORD=1
RESTART_WEB=1
BUILD_ONLY=0

for arg in "$@"; do
  case "$arg" in
    --discord)    RESTART_WEB=0 ;;
    --web)        RESTART_DISCORD=0 ;;
    --build-only) BUILD_ONLY=1; RESTART_DISCORD=0; RESTART_WEB=0 ;;
  esac
done

mkdir -p logs
LOG="$ROOT/logs/deploy-mac.log"
ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }
log() { echo "[$(ts)] $*" | tee -a "$LOG"; }

log "deploy-mac: start (discord=$RESTART_DISCORD web=$RESTART_WEB)"

# --- Load env ---
if [[ -f .env ]]; then set -a; source .env; set +a; fi

# --- Wait for cargo build lock before killing any running process ---
# Avoids the "Blocking waiting for file lock on artifact directory" issue
# when an Android cross-compile is already running in the background.
LOCK_WAIT_MAX="${DEPLOY_MAC_TIMEOUT:-600}"
LOCK_POLL=5
lock_waited=0
while true; do
  # Try a no-op check: if cargo can't get the lock it prints the blocking message to stderr.
  if cargo build --release --message-format=short 2>&1 | grep -q "Blocking waiting for file lock" ; then
    if [[ $lock_waited -ge $LOCK_WAIT_MAX ]]; then
      log "ERROR: cargo build lock held >$LOCK_WAIT_MAX s; giving up."
      exit 1
    fi
    log "  Waiting for cargo build lock (another build in progress)... ${lock_waited}s elapsed"
    sleep $LOCK_POLL
    lock_waited=$((lock_waited + LOCK_POLL))
    continue
  fi
  break
done

# --- Build ---
log "Building release binary..."
BUILD_START=$(date +%s)
cargo build --release 2>&1 | tee -a "$LOG"
BUILD_END=$(date +%s)
log "Build done in $((BUILD_END - BUILD_START))s."

if [[ "$BUILD_ONLY" -eq 1 ]]; then
  log "deploy-mac: build-only, skipping restart."
  exit 0
fi

# --- Hot-swap Discord bot ---
if [[ "$RESTART_DISCORD" -eq 1 ]]; then
  log "Restarting Discord bot..."
  pkill -f "chump.*--discord" 2>/dev/null || true
  pkill -f "rust-agent.*--discord" 2>/dev/null || true
  # Wait for clean exit (up to 5s) before launching new process
  for _ in 1 2 3 4 5; do
    (pgrep -f "chump.*--discord" >/dev/null 2>&1 || pgrep -f "rust-agent.*--discord" >/dev/null 2>&1) || break
    sleep 1
  done
  nohup ./run-discord.sh >> logs/discord.log 2>&1 &
  DISCORD_PID=$!
  sleep 3
  if pgrep -f "chump.*--discord" >/dev/null 2>&1 || pgrep -f "rust-agent.*--discord" >/dev/null 2>&1; then
    log "Discord bot started (PID $DISCORD_PID)."
  else
    log "WARNING: Discord bot may not have started. Check logs/discord.log"
  fi
fi

# --- Hot-swap Web bot ---
if [[ "$RESTART_WEB" -eq 1 ]]; then
  WEB_PORT="${CHUMP_WEB_PORT:-3000}"
  log "Restarting Web bot (port $WEB_PORT)..."
  pkill -f "chump.*--web" 2>/dev/null || true
  pkill -f "rust-agent.*--web" 2>/dev/null || true
  for _ in 1 2 3 4 5; do
    (pgrep -f "chump.*--web" >/dev/null 2>&1 || pgrep -f "rust-agent.*--web" >/dev/null 2>&1) || break
    sleep 1
  done
  if [[ -f run-web.sh ]]; then
    nohup bash run-web.sh >> logs/web.log 2>&1 &
  else
    nohup ./target/release/chump --web --port "$WEB_PORT" >> logs/web.log 2>&1 &
  fi
  WEB_PID=$!
  sleep 3
  if pgrep -f "chump.*--web" >/dev/null 2>&1 || pgrep -f "rust-agent.*--web" >/dev/null 2>&1; then
    log "Web bot started (PID $WEB_PID)."
  else
    log "WARNING: Web bot may not have started. Check logs/web.log"
  fi
fi

log "deploy-mac: done."
echo ""
echo "Run ./scripts/fleet-health.sh to verify both bots are healthy."
