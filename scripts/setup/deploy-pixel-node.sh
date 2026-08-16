#!/usr/bin/env bash
# deploy-pixel-node.sh — RESILIENT-336: build → warm → hot-swap the Pixel node binary.
# Runs on the Mac. Cross-compiles aarch64, uploads to chump.new (never touches the
# running binary), validates the new binary answers a smoke prompt (WARM), then
# atomically swaps it in and bounces the worker (HOT). The supervisor restarts the
# worker, which picks up the new binary on its next cycle.
#
# Usage:
#   ./scripts/setup/deploy-pixel-node.sh [pixel_ssh_target]
#
# Env:
#   PIXEL_SSH_TARGET   ssh target (default u0_a314@127.0.0.1 over ADB-forwarded :8022)
#   PIXEL_SSH_PORT     ssh port (default 8022)
#   CHUMP_HOME_REMOTE  remote deploy dir (default ~/chump)

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
cd "$REPO_ROOT"

SSH_PORT="${PIXEL_SSH_PORT:-8022}"
SSH_TARGET="${PIXEL_SSH_TARGET:-u0_a314@127.0.0.1}"
SSH_OPTS=( -o ConnectTimeout=8 -o BatchMode=yes -o StrictHostKeyChecking=no
           -o UserKnownHostsFile=/dev/null -p "$SSH_PORT" )
REMOTE="${CHUMP_HOME_REMOTE:-~/chump}"

# ── 1. Cross-compile (build-android.sh handles NDK + rust-std + --no-default-features) ──
echo "[deploy-pixel] building aarch64 binary..."
"$HERE/build-android.sh"

BIN="$REPO_ROOT/target-android/aarch64-linux-android/release/chump"
[ -f "$BIN" ] || { echo "[deploy-pixel] build produced no binary at $BIN" >&2; exit 1; }

# ── 2. Upload to chump.new (the running binary stays untouched) ───────────────────────
echo "[deploy-pixel] uploading to $SSH_TARGET:$REMOTE/chump.new"
scp "${SSH_OPTS[@]}" "$BIN" "$SSH_TARGET:$REMOTE/chump.new"

# ── 3. WARM: the new binary must answer a cascade smoke prompt before the swap ────────
echo "[deploy-pixel] warming chump.new (cascade smoke)..."
WARM_OUT="$(ssh "${SSH_OPTS[@]}" "$SSH_TARGET" \
    "cd $REMOTE && set -a && . ./.env 2>/dev/null; set +a; echo 'Say exactly: WARM_OK' | timeout 60 ./chump.new llm-complete --system 'You are a boot check. Reply with exactly WARM_OK.' --max-tokens 16 2>&1 || true")"
if ! grep -q 'WARM_OK' <<<"$WARM_OUT"; then
    echo "[deploy-pixel] WARM FAILED — new binary did not answer. Aborting swap (chump.new left in place)." >&2
    echo "  output: $(tail -3 <<<"$WARM_OUT")" >&2
    exit 1
fi
echo "[deploy-pixel] warm OK"

# ── 4. HOT SWAP: atomically move into place + bounce the worker ───────────────────────
echo "[deploy-pixel] swapping + bouncing worker..."
ssh "${SSH_OPTS[@]}" "$SSH_TARGET" \
    "mv $REMOTE/chump.new $REMOTE/chump && pkill -f 'chump --execute[.-]gap' 2>/dev/null; pkill -f 'pixel-worker[.]sh' 2>/dev/null; echo swapped" \
    || { echo "[deploy-pixel] swap failed" >&2; exit 1; }

echo "[deploy-pixel] done — supervisor will respawn the worker on the new binary."
