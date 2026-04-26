#!/usr/bin/env bash
# Probe inference mesh nodes: Mac :8000, iPhone :8889 (Tailscale), optionally Pixel via SSH.
# Run from Chump repo root on the Mac. See docs/architecture/INFERENCE_MESH.md.
#
# Usage: ./scripts/check-inference-mesh.sh

set -e
ROOT="${CHUMP_HOME:-$(cd "$(dirname "$0")/.." && pwd)}"
cd "$ROOT"
if [[ -f .env ]]; then
  set -a
  source .env
  set +a
fi

MAC_URL="${INFERENCE_MESH_MAC_URL:-http://127.0.0.1:8000/v1/models}"
IPHONE_URL="${INFERENCE_MESH_IPHONE_URL:-http://10.1.10.175:8889/v1/models}"
PIXEL_SSH="${PIXEL_SSH_HOST:-termux}"
PIXEL_PORT="${PIXEL_SSH_PORT:-8022}"
TIMEOUT=5

probe() {
  local name="$1" url="$2"
  if curl -s -m "$TIMEOUT" -o /dev/null -w "%{http_code}" "$url" 2>/dev/null | grep -q '^2'; then
    echo "  $name: UP"
    return 0
  else
    echo "  $name: DOWN"
    return 1
  fi
}

echo "=== Inference mesh ==="
echo ""

echo "Mac (localhost:8000)..."
probe "Mac" "$MAC_URL" || true
echo ""

echo "iPhone (Tailscale :8889)..."
probe "iPhone" "$IPHONE_URL" || true
echo ""

echo "Pixel (via SSH to $PIXEL_SSH:$PIXEL_PORT)..."
if ssh -o ConnectTimeout=5 -o BatchMode=yes -p "$PIXEL_PORT" "$PIXEL_SSH" "curl -s -m $TIMEOUT -o /dev/null -w '%{http_code}' http://127.0.0.1:8000/v1/models 2>/dev/null" 2>/dev/null | grep -q '^2'; then
  echo "  Pixel: UP"
else
  echo "  Pixel: DOWN (or SSH failed; check ~/.ssh/config and docs/NETWORK_SWAP.md)"
fi
echo ""

echo "Override URLs with INFERENCE_MESH_MAC_URL / INFERENCE_MESH_IPHONE_URL. See docs/architecture/INFERENCE_MESH.md."
