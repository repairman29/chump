#!/usr/bin/env bash
# nats-jetstream-block-install.sh — RESILIENT-1467 (RESILIENT-1466 slice)
#
# Idempotently appends a JetStream block to /etc/nats/nats.conf. Companion to
# scripts/setup/nats-broker-install.sh (which writes a full nats.conf from
# scratch) — this script targets hosts where nats.conf already exists
# (hand-written or installed some other way) and just needs JetStream turned
# on without clobbering the rest of the file.
#
# Safe to re-run: if a `jetstream {` block is already present, this is a
# no-op. Otherwise it backs up the existing file with a timestamped filename
# before appending.
#
# Usage:
#   bash scripts/setup/nats-jetstream-block-install.sh
#   NATS_CONF=/path/to/nats.conf bash scripts/setup/nats-jetstream-block-install.sh   # override target (tests)
set -euo pipefail

log() { printf '[nats-jetstream-block-install] %s\n' "$*"; }
die() { printf '[nats-jetstream-block-install] ERROR: %s\n' "$*" >&2; exit 1; }

CONF="${NATS_CONF:-/etc/nats/nats.conf}"
STORE_DIR="/var/lib/nats/jetstream"

# Use sudo only when the target isn't already writable by the current user
# (real /etc/nats/nats.conf on the hub) — lets tests point NATS_CONF at a
# writable temp file with no sudo required.
_priv() {
  if [[ -w "$CONF" ]] || { [[ ! -e "$CONF" ]] && [[ -w "$(dirname "$CONF")" ]]; }; then
    "$@"
  elif [[ "$(id -u)" -eq 0 ]]; then
    "$@"
  else
    sudo "$@"
  fi
}

[[ -f "$CONF" ]] || die "$CONF not found — run nats-broker-install.sh (or hand-install nats.conf) first"

if _priv grep -q '^jetstream {' "$CONF"; then
  log "jetstream block already present in $CONF — no-op"
  exit 0
fi

TS="$(date -u +%Y%m%dT%H%M%SZ)"
BACKUP="${CONF}.bak.${TS}"
_priv cp "$CONF" "$BACKUP"
log "backed up $CONF -> $BACKUP"

_priv mkdir -p "$STORE_DIR"

_priv bash -c "cat >> '$CONF'" <<BLOCK

jetstream {
  store_dir: $STORE_DIR
  max_mem: 256MB
  max_file: 2GB
}
BLOCK

log "appended jetstream block to $CONF (store_dir=$STORE_DIR, max_mem=256MB, max_file=2GB)"
exit 0
