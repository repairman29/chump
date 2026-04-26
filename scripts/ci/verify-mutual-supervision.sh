#!/usr/bin/env bash
# Verify mutual supervision: Mac can restart Mabel's heartbeat on the Pixel, and the
# Chump restart script runs successfully on the Mac (so when Pixel SSHs in and runs it, it works).
# Run from Chump repo root on the Mac. Loads .env for PIXEL_SSH_HOST, PIXEL_SSH_PORT.
# Exit 0 if both checks pass; exit 1 otherwise (prints OK/FAIL per check).

set -e
ROOT="${CHUMP_HOME:-$(cd "$(dirname "$0")/.." && pwd)}"
cd "$ROOT"
if [[ -f "$ROOT/.env" ]]; then
  set -a
  # shellcheck source=/dev/null
  source "$ROOT/.env"
  set +a
fi

PIXEL_HOST="${PIXEL_SSH_HOST:-}"
PIXEL_PORT="${PIXEL_SSH_PORT:-8022}"

OK=0
FAIL=0

# 1) Mac -> Pixel: restart Mabel's heartbeat
if [[ -n "$PIXEL_HOST" ]]; then
  if ssh -o ConnectTimeout=15 -o StrictHostKeyChecking=no -p "$PIXEL_PORT" "$PIXEL_HOST" 'cd ~/chump && bash scripts/setup/restart-mabel-heartbeat.sh' 2>/dev/null; then
    echo "OK  Mac->Pixel: restart-mabel-heartbeat.sh"
    ((OK++)) || true
  else
    echo "FAIL Mac->Pixel: restart-mabel-heartbeat.sh (check PIXEL_SSH_HOST=$PIXEL_HOST, port $PIXEL_PORT, SSH key, ~/chump on Pixel)"
    ((FAIL++)) || true
  fi
else
  echo "SKIP Mac->Pixel: PIXEL_SSH_HOST not set"
fi

# 2) Chump restart on Mac (same script Pixel runs via SSH)
if bash "$ROOT/scripts/setup/restart-chump-heartbeat.sh" 2>/dev/null; then
  echo "OK  Chump restart on Mac (script that Pixel runs via SSH)"
  ((OK++)) || true
else
  echo "FAIL Chump restart on Mac (script that Pixel runs via SSH)"
  ((FAIL++)) || true
fi

if [[ $FAIL -gt 0 ]]; then
  echo "verify-mutual-supervision: $OK ok, $FAIL fail"
  exit 1
fi
echo "verify-mutual-supervision: all $OK checks passed"
exit 0
