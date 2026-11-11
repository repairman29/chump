#!/usr/bin/env bash
# nats-cloud-stream-install.sh — RESILIENT-1466: idempotently create the CLOUD
# JetStream stream (chump.cloud.>, file, limits 30d/1GB). Requires JetStream on
# (see nats-jetstream-block-install.sh) and the nats CLI (v0.1+; install:
# https://github.com/nats-io/natscli/releases -> ~/.local/bin/nats).
set -euo pipefail
url="${CHUMP_NATS_URL:-nats://127.0.0.1:4222}"
command -v nats >/dev/null 2>&1 || { echo "[nats-cloud-stream] nats CLI missing — install natscli (see docs/process/CLOUD_AGENT_STATUS.md)" >&2; exit 1; }
if nats --server "$url" stream info CLOUD >/dev/null 2>&1; then
  echo "[nats-cloud-stream] CLOUD stream already present — no-op"; exit 0
fi
nats --server "$url" stream add CLOUD --subjects 'chump.cloud.>' --storage file \
  --retention limits --max-age 30d --max-bytes 1GB --max-msgs=-1 --max-msg-size=-1 \
  --discard old --dupe-window 2m --replicas 1 --defaults >/dev/null
echo "[nats-cloud-stream] created CLOUD stream"
