#!/usr/bin/env bash
# Run Mabel setup on the Pixel via Termux SSH. Use after enabling sshd in Termux once.
#
# One-time in Termux:  pkg install openssh && sshd && whoami
# Then from Mac:       ./scripts/setup/run-setup-via-ssh.sh [termux_user@]pixel_ip
#
# Examples:
#   ./scripts/setup/run-setup-via-ssh.sh u0_a284@10.1.10.9
#   TERMUX_USER=u0_a284 PIXEL_IP=10.1.10.9 ./scripts/setup/run-setup-via-ssh.sh

set -e
SCRIPT_DIR="$(dirname "$0")"

PIXEL_IP="${PIXEL_IP:-10.1.10.9}"
TERMUX_USER="${TERMUX_USER:-}"
SSH_PORT="${SSH_PORT:-8022}"

if [[ -n "$1" ]]; then
  if [[ "$1" == *"@"* ]]; then
    TERMUX_USER="${1%%@*}"
    PIXEL_IP="${1##*@}"
  else
    PIXEL_IP="$1"
  fi
fi

if [[ -z "$TERMUX_USER" ]]; then
  echo "Usage: $0 [termux_user@]pixel_ip"
  echo "  e.g. $0 u0_a284@10.1.10.9"
  echo "  In Termux run: whoami   (then use that as termux_user)"
  exit 1
fi

DEST="${TERMUX_USER}@${PIXEL_IP}"
echo "Running setup on Termux via SSH (${DEST}:${SSH_PORT})..."
# Background so companion keeps running after SSH disconnects; logs in ~/chump/logs/
ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 -p "$SSH_PORT" "$DEST" \
  "mkdir -p ~/chump/logs && nohup bash /sdcard/Download/chump/setup-and-run.sh >> ~/chump/logs/setup.log 2>&1 & sleep 2; echo 'Mabel starting in background. Logs: ~/chump/logs/'"
