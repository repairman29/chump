#!/usr/bin/env bash
# install-tailscale.sh — FLEET-013: bring up Tailscale + discover the chump
# NATS broker on the tailnet.
#
# Distributed agents live on a Tailscale VPN so the NATS broker doesn't need
# to be internet-exposed and agents on different physical machines can find
# each other via Tailscale's MagicDNS (hostname.tailnet.ts.net).
#
# This script is idempotent — safe to re-run on a machine that's already
# joined the tailnet. It does NOT auto-rotate auth keys; if `tailscale up`
# requires re-authentication you'll get an interactive URL.
#
# What it does:
#   1. brew install tailscale  (skip if installed)
#   2. tailscale up             (skip if already up; uses TS_AUTHKEY if set)
#   3. Discover NATS broker:
#      - Use $CHUMP_NATS_BROKER_HOST if set (e.g. "chump-nats.tail-scale.ts.net")
#      - Else probe :4222 on each tailnet peer; first responder wins
#      - Else fall back to localhost
#   4. Write CHUMP_NATS_URL to ~/.chump/env so subsequent agent processes
#      pick it up (sourced by chump-orchestrator and friends)
#
# Run once per fleet machine. Safe to re-run after a Tailscale restart or
# broker move.
#
# Bypass for offline / development: CHUMP_SKIP_TAILSCALE=1 just writes
# the localhost fallback URL.
#
# Tunables:
#   CHUMP_NATS_BROKER_HOST   override discovery (e.g. "myhost.foo.ts.net")
#   CHUMP_NATS_PORT          default 4222
#   TS_AUTHKEY               passed to `tailscale up` for unattended bootstrap
#                            (recommended for CI / fleet-launcher invocations)
#   CHUMP_TAILSCALE_HOSTNAME override the device hostname (default: machine hostname)

set -euo pipefail

ENV_FILE="${HOME}/.chump/env"
mkdir -p "${HOME}/.chump"
NATS_PORT="${CHUMP_NATS_PORT:-4222}"

say()  { printf '\033[1;36m[install-tailscale]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[install-tailscale]\033[0m %s\n' "$*" >&2; }

# ── 0. Bypass for offline / dev ──────────────────────────────────────────────
if [[ "${CHUMP_SKIP_TAILSCALE:-0}" == "1" ]]; then
    say "CHUMP_SKIP_TAILSCALE=1 — writing localhost fallback to $ENV_FILE"
    printf 'CHUMP_NATS_URL=nats://127.0.0.1:%s\n' "$NATS_PORT" > "$ENV_FILE"
    exit 0
fi

# ── 1. Ensure tailscale binary is installed ──────────────────────────────────
if ! command -v tailscale >/dev/null 2>&1; then
    say "tailscale not found — installing via brew"
    if ! command -v brew >/dev/null 2>&1; then
        warn "ERROR: brew not found. Install Homebrew first (or install tailscale manually)."
        exit 1
    fi
    brew install tailscale
else
    say "tailscale already installed ($(tailscale version 2>/dev/null | head -1))"
fi

# ── 2. Bring up tailscale (idempotent) ───────────────────────────────────────
TS_STATUS_JSON="$(tailscale status --json 2>/dev/null || echo '{}')"
TS_BACKEND="$(printf '%s' "$TS_STATUS_JSON" | python3 -c "
import json, sys
try:
    d = json.load(sys.stdin)
    print(d.get('BackendState', 'Unknown'))
except Exception:
    print('Unknown')
")"

if [[ "$TS_BACKEND" != "Running" ]]; then
    say "tailscale not running (BackendState=$TS_BACKEND); starting"
    UP_ARGS=(--accept-dns=true --accept-routes=true)
    [[ -n "${CHUMP_TAILSCALE_HOSTNAME:-}" ]] && UP_ARGS+=(--hostname="${CHUMP_TAILSCALE_HOSTNAME}")
    if [[ -n "${TS_AUTHKEY:-}" ]]; then
        UP_ARGS+=(--auth-key="${TS_AUTHKEY}")
        say "  unattended (TS_AUTHKEY set)"
    else
        say "  interactive — open the URL Tailscale prints to authorize this device"
    fi
    if ! sudo tailscale up "${UP_ARGS[@]}"; then
        warn "tailscale up failed; falling back to localhost broker"
        printf 'CHUMP_NATS_URL=nats://127.0.0.1:%s\n' "$NATS_PORT" > "$ENV_FILE"
        exit 1
    fi
else
    say "tailscale already up; using existing tailnet"
fi

# Re-fetch status after up
TS_STATUS_JSON="$(tailscale status --json 2>/dev/null || echo '{}')"

# ── 3. Discover the NATS broker ──────────────────────────────────────────────
# Priority order:
#   1. $CHUMP_NATS_BROKER_HOST (explicit override; canonical for fleet-launcher)
#   2. Probe each tailnet peer (HostName) on :$NATS_PORT; first responder wins
#   3. Fall back to localhost
NATS_HOST=""

if [[ -n "${CHUMP_NATS_BROKER_HOST:-}" ]]; then
    say "using explicit CHUMP_NATS_BROKER_HOST=$CHUMP_NATS_BROKER_HOST"
    NATS_HOST="$CHUMP_NATS_BROKER_HOST"
else
    say "probing tailnet peers on :$NATS_PORT (3s timeout each)…"
    PEERS="$(printf '%s' "$TS_STATUS_JSON" | python3 -c "
import json, sys
try:
    d = json.load(sys.stdin)
    self_dns = d.get('Self',{}).get('DNSName','').rstrip('.')
    peers = []
    if self_dns:
        peers.append(self_dns)
    for p in (d.get('Peer') or {}).values():
        dns = (p.get('DNSName') or '').rstrip('.')
        if dns:
            peers.append(dns)
    print('\n'.join(peers))
except Exception:
    pass
")"
    while IFS= read -r host; do
        [[ -z "$host" ]] && continue
        # Quick TCP probe via /dev/tcp (bash builtin, no nc dependency)
        if (echo > "/dev/tcp/${host}/${NATS_PORT}") 2>/dev/null; then
            say "  found NATS at $host:$NATS_PORT"
            NATS_HOST="$host"
            break
        fi
    done <<<"$PEERS"
fi

if [[ -z "$NATS_HOST" ]]; then
    warn "no NATS broker found on tailnet; falling back to localhost"
    NATS_HOST="127.0.0.1"
fi

# ── 4. Write CHUMP_NATS_URL to env file ──────────────────────────────────────
NATS_URL="nats://${NATS_HOST}:${NATS_PORT}"
say "writing CHUMP_NATS_URL=${NATS_URL} to $ENV_FILE"
{
    echo "# FLEET-013: discovered NATS broker via Tailscale"
    echo "# Generated by scripts/setup/install-tailscale.sh on $(date -u +%FT%TZ)"
    echo "# Re-run install-tailscale.sh to refresh after a broker move."
    echo "CHUMP_NATS_URL=${NATS_URL}"
} > "$ENV_FILE"

say "done. Source it with: source $ENV_FILE  (or run install-tailscale.sh from your shell rc)"
say "Verify: chump-coord ping  (or: nc -zv $NATS_HOST $NATS_PORT)"
