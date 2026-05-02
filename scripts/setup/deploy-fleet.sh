#!/usr/bin/env bash
# deploy-fleet.sh — single command to build + deploy the entire Chump fleet.
#
# What it does:
#   1. Build Mac binary  (cargo build --release, native target)
#   2. Build Android binary  (cargo build --release, aarch64-linux-android, separate target-dir)
#      Steps 1 and 2 run in PARALLEL since they now use different artifact dirs.
#   3. Hot-swap Mac Discord + Web bots
#   4. Deploy Android binary + scripts + env to Pixel; restart Mabel
#   5. Run fleet-health.sh to verify everything came up
#
# Usage:
#   ./scripts/setup/deploy-fleet.sh              # full fleet deploy
#   ./scripts/setup/deploy-fleet.sh --mac        # Mac only (skip Pixel)
#   ./scripts/setup/deploy-fleet.sh --pixel      # Pixel only (skip Mac; reuses existing Android binary if fresh)
#   ./scripts/setup/deploy-fleet.sh --no-build   # skip both builds (re-deploy existing binaries)
#   ./scripts/setup/deploy-fleet.sh --health     # health check only; no deploy
#
# Env overrides:
#   DEPLOY_PIXEL_HOST  SSH host for Pixel (default: PIXEL_SSH_HOST from .env, then "termux")
#   DEPLOY_PORT        SSH port for Pixel (default: PIXEL_SSH_PORT from .env, then 8022)
#   ANDROID_TARGET_DIR separate target dir for Android build (default: ./target-android)
#   DEPLOY_SKIP_STRIP  set to 1 to skip binary stripping

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$ROOT"

# --- Parse flags ---
DEPLOY_MAC=1
DEPLOY_PIXEL=1
BUILD=1
HEALTH_ONLY=0

for arg in "$@"; do
  case "$arg" in
    --mac)      DEPLOY_PIXEL=0 ;;
    --pixel)    DEPLOY_MAC=0 ;;
    --no-build) BUILD=0 ;;
    --health)   HEALTH_ONLY=1; BUILD=0; DEPLOY_MAC=0; DEPLOY_PIXEL=0 ;;
  esac
done

mkdir -p logs
LOG="$ROOT/logs/deploy-fleet.log"
ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }
log() { local msg="[$(ts)] $*"; echo "$msg"; echo "$msg" >> "$LOG"; }

# --- Load env ---
[[ -f .env ]] && set -a && source .env && set +a
PIXEL_HOST="${DEPLOY_PIXEL_HOST:-${PIXEL_SSH_HOST:-termux}}"
PIXEL_PORT="${DEPLOY_PORT:-${PIXEL_SSH_PORT:-8022}}"

log "=== deploy-fleet: mac=$DEPLOY_MAC pixel=$DEPLOY_PIXEL build=$BUILD ==="

# --- Health only ---
if [[ "$HEALTH_ONLY" -eq 1 ]]; then
  bash "$ROOT/scripts/dev/fleet-health.sh"
  exit $?
fi

# ── Phase 1: Parallel builds ───────────────────────────────────────────────
MAC_BUILD_OK=0
ANDROID_BUILD_OK=0
MAC_BUILD_LOG="$ROOT/logs/build-mac.log"
ANDROID_BUILD_LOG="$ROOT/logs/build-android.log"

if [[ "$BUILD" -eq 1 ]]; then
  log "Phase 1: building Mac + Android in parallel..."

  # Mac build in background
  MAC_BUILD_PID=""
  if [[ "$DEPLOY_MAC" -eq 1 ]]; then
    (
      set -e
      cargo build --release >>"$MAC_BUILD_LOG" 2>&1
      echo "MAC_BUILD_SUCCESS" >> "$MAC_BUILD_LOG"
    ) &
    MAC_BUILD_PID=$!
    log "  Mac build started (PID $MAC_BUILD_PID) → $MAC_BUILD_LOG"
  fi

  # Android build in foreground (needs NDK env; easier to surface errors)
  if [[ "$DEPLOY_PIXEL" -eq 1 ]]; then
    log "  Android build starting → $ANDROID_BUILD_LOG"
    if bash "$SCRIPT_DIR/build-android.sh" >>"$ANDROID_BUILD_LOG" 2>&1; then
      ANDROID_BUILD_OK=1
      log "  Android build: OK"
    else
      log "  Android build: FAILED — check $ANDROID_BUILD_LOG"
    fi
  fi

  # Wait for Mac build
  if [[ -n "${MAC_BUILD_PID:-}" ]]; then
    if wait "$MAC_BUILD_PID" 2>/dev/null; then
      if grep -q "MAC_BUILD_SUCCESS" "$MAC_BUILD_LOG" 2>/dev/null; then
        MAC_BUILD_OK=1
        log "  Mac build: OK"
      else
        log "  Mac build: FAILED — check $MAC_BUILD_LOG"
      fi
    else
      log "  Mac build: FAILED (exit non-zero) — check $MAC_BUILD_LOG"
    fi
  fi
else
  log "Phase 1: skipping builds (--no-build)."
  MAC_BUILD_OK=1
  ANDROID_BUILD_OK=1
fi

# ── Phase 2: Deploy Mac ────────────────────────────────────────────────────
if [[ "$DEPLOY_MAC" -eq 1 ]]; then
  if [[ "$BUILD" -eq 1 ]] && [[ "$MAC_BUILD_OK" -eq 0 ]]; then
    log "Phase 2: SKIP Mac deploy — build failed."
  else
    log "Phase 2: deploying Mac bots..."
    # deploy-mac.sh --build-only skips rebuild since we already built above
    if bash "$SCRIPT_DIR/deploy-mac.sh" --build-only >>"$LOG" 2>&1; then
      log "  Mac binaries ready. Hot-swapping processes..."
      # Kill and restart Discord bot
      pkill -f "chump.*--discord" 2>/dev/null || true
      pkill -f "rust-agent.*--discord" 2>/dev/null || true
      sleep 2
      nohup ./run-discord.sh >> logs/discord.log 2>&1 &
      log "  Discord bot restarted."
      # Kill and restart Web bot
      WEB_PORT="${CHUMP_WEB_PORT:-3000}"
      pkill -f "chump.*--web" 2>/dev/null || true
      pkill -f "rust-agent.*--web" 2>/dev/null || true
      sleep 1
      if [[ -f run-web.sh ]]; then
        nohup bash run-web.sh >> logs/web.log 2>&1 &
      else
        nohup ./target/release/chump --web --port "$WEB_PORT" >> logs/web.log 2>&1 &
      fi
      log "  Web bot restarted."
      sleep 4  # give bots time to connect before health check
    else
      log "  Mac deploy script error — check $LOG"
    fi
  fi
fi

# ── Phase 3: Deploy Pixel ──────────────────────────────────────────────────
if [[ "$DEPLOY_PIXEL" -eq 1 ]]; then
  if [[ "$BUILD" -eq 1 ]] && [[ "$ANDROID_BUILD_OK" -eq 0 ]]; then
    log "Phase 3: SKIP Pixel deploy — Android build failed."
  else
    log "Phase 3: deploying to Pixel ($PIXEL_HOST:$PIXEL_PORT)..."
    if bash "$SCRIPT_DIR/deploy-all-to-pixel.sh" "$PIXEL_HOST" >>"$LOG" 2>&1; then
      log "  Pixel deploy: OK"
    else
      log "  Pixel deploy: FAILED — check $LOG"
    fi
  fi
fi

# ── Phase 4: Fleet health check ────────────────────────────────────────────
log "Phase 4: fleet health check..."
echo ""
# Health flags based on what we deployed
HEALTH_FLAGS=""
[[ "$DEPLOY_MAC"   -eq 0 ]] && HEALTH_FLAGS="--pixel"
[[ "$DEPLOY_PIXEL" -eq 0 ]] && HEALTH_FLAGS="--mac"

bash "$ROOT/scripts/dev/fleet-health.sh" ${HEALTH_FLAGS:-} || true

log "=== deploy-fleet: done ==="
echo ""
echo "Full log: $LOG"
