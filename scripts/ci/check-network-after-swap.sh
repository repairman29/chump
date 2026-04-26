#!/usr/bin/env bash
# After a network swap: print Mac Tailscale IP, test SSH to Pixel (termux), remind to update Pixel .env.
# Run from Chump repo root on the Mac. See docs/NETWORK_SWAP.md.
#
# Usage: ./scripts/ci/check-network-after-swap.sh

set -e
ROOT="${CHUMP_HOME:-$(cd "$(dirname "$0")/../.." && pwd)}"
cd "$ROOT"
PORT="${DEPLOY_PORT:-8022}"

echo "=== Network check (after swap) ==="
echo ""

# Mac Tailscale IP (for Pixel's MAC_TAILSCALE_IP)
if command -v tailscale &>/dev/null; then
  MAC_IP=$(tailscale ip -4 2>/dev/null || true)
  if [[ -n "$MAC_IP" ]]; then
    echo "Mac Tailscale IP (set this as MAC_TAILSCALE_IP on Pixel): $MAC_IP"
  else
    echo "Mac Tailscale IP: (run 'tailscale ip -4' if Tailscale is up)"
  fi
else
  echo "Mac Tailscale IP: (install Tailscale and run 'tailscale ip -4')"
fi
echo ""

# SSH to Pixel
echo "Testing SSH to termux (port $PORT)..."
if ssh -o ConnectTimeout=10 -o BatchMode=yes -p "$PORT" termux "echo ok" 2>/dev/null; then
  echo "  SSH to termux: OK"
else
  echo "  SSH to termux: FAIL (update ~/.ssh/config Host termux → HostName = Pixel IP; see docs/NETWORK_SWAP.md)"
fi
echo ""

echo "On the Pixel, ensure ~/chump/.env has MAC_TAILSCALE_IP=<Mac Tailscale IP>."
echo "Then restart Mabel if needed. Full checklist: docs/NETWORK_SWAP.md"
