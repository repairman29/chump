#!/usr/bin/env bash
# wire-pixel-ssh.sh — INFRA-3664: wire Pixel as reachable-from-CJ (2nd owned
# build/shipper node). Run ON the box that needs to reach Pixel (e.g. CJ).
#
# Corrects the stale reachability data this gap was filed against:
#   - Pixel's tailnet IP is 100.84.132.93 (NOT 100.90.52.126 — that's CJ's own
#     tailnet IP; the gap's diagnostic was testing the wrong host).
#   - Termux sshd listens on port 8022, not 22 (Termux runs unprivileged;
#     it cannot bind <1024). `nc -zv <ip> 22` will always read "unreachable"
#     against a stock Termux install — that is not a reachability fault.
#   - Termux ssh user is the app's Linux UID alias (e.g. u0_a314), not a
#     tailnet device name or "termux".
#
# What this script does (🤖 scriptable):
#   1. generates a dedicated ed25519 keypair (~/.ssh/chump_pixel) if absent
#   2. writes/updates a `Host pixel` block in ~/.ssh/config so `ssh pixel`
#      resolves+connects once the pubkey is authorized
#   3. tests connectivity + prints the exact 🧑 operator step remaining
#      (pubkey → Termux authorized_keys — a credential action, never scripted
#      per RESILIENT-173 / ADD_A_FLEET_NODE.md)
#
# Usage:
#   scripts/setup/wire-pixel-ssh.sh [--ip IP] [--port PORT] [--user USER]
set -euo pipefail

PIXEL_IP="${PIXEL_IP:-100.84.132.93}"
PIXEL_PORT="${PIXEL_PORT:-8022}"
PIXEL_USER="${PIXEL_USER:-u0_a314}"

while [ $# -gt 0 ]; do
  case "$1" in
    --ip) PIXEL_IP="$2"; shift 2;;
    --port) PIXEL_PORT="$2"; shift 2;;
    --user) PIXEL_USER="$2"; shift 2;;
    -h|--help) grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0;;
    *) echo "unknown arg: $1" >&2; exit 2;;
  esac
done

SSH_DIR="$HOME/.ssh"
KEY="$SSH_DIR/chump_pixel"
CONFIG="$SSH_DIR/config"

mkdir -p "$SSH_DIR"
chmod 700 "$SSH_DIR"

if [ ! -f "$KEY" ]; then
  echo "[wire-pixel-ssh] generating dedicated keypair at $KEY"
  ssh-keygen -t ed25519 -f "$KEY" -N "" -C "$(hostname)-chump-pixel" >/dev/null
else
  echo "[wire-pixel-ssh] reusing existing keypair at $KEY"
fi

touch "$CONFIG"
chmod 600 "$CONFIG"
if ! grep -q '^Host pixel$' "$CONFIG" 2>/dev/null; then
  echo "[wire-pixel-ssh] adding Host pixel block to $CONFIG"
  {
    echo ""
    echo "Host pixel"
    echo "  HostName $PIXEL_IP"
    echo "  Port $PIXEL_PORT"
    echo "  User $PIXEL_USER"
    echo "  IdentityFile $KEY"
    echo "  IdentitiesOnly yes"
    echo "  StrictHostKeyChecking accept-new"
    echo "  ConnectTimeout 8"
  } >> "$CONFIG"
else
  echo "[wire-pixel-ssh] Host pixel block already present in $CONFIG (leaving as-is)"
fi

echo ""
if ssh -o BatchMode=yes -o ConnectTimeout=8 pixel echo ok >/dev/null 2>&1; then
  echo "[wire-pixel-ssh] REACHABLE — ssh pixel works."
  exit 0
fi

echo "[wire-pixel-ssh] ssh pixel does not yet authenticate — this is the ONE"
echo "operator (🧑) step left: authorize this box's pubkey on the phone."
echo ""
echo "  1. Open Termux on the Pixel"
echo "  2. Run:"
echo "       mkdir -p ~/.ssh && chmod 700 ~/.ssh"
echo "       echo '$(cat "$KEY.pub")' >> ~/.ssh/authorized_keys"
echo "       chmod 600 ~/.ssh/authorized_keys"
echo "  3. Re-run this script (or: ssh pixel echo ok) to confirm."
echo ""
echo "Pubkey also available at: $KEY.pub"
exit 1
