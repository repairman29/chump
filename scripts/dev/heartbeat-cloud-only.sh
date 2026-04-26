#!/usr/bin/env bash
# Cloud-only heartbeat: run self-improve rounds using the provider cascade only (no local model).
# Use when the Mac is sleeping, Ollama/8000 is down, or you want to drive rounds from a headless
# host (e.g. cron on Pixel or a $0 cloud function). No preflight for local model.
#
# Requires: .env with cascade slot keys (e.g. CHUMP_PROVIDER_1_KEY, CHUMP_PROVIDER_2_KEY).
# Build first: cargo build --release
#
# Usage:
#   ./scripts/dev/heartbeat-cloud-only.sh
#   HEARTBEAT_DURATION=4h HEARTBEAT_INTERVAL=8m ./scripts/dev/heartbeat-cloud-only.sh
#
# Logs: logs/heartbeat-self-improve.log (same as heartbeat-self-improve.sh).

set -e
ROOT="${CHUMP_HOME:-$(cd "$(dirname "$0")/.." && pwd)}"
cd "$ROOT"
export PATH="${HOME}/.local/bin:${PATH}"

if [[ -f .env ]]; then
  set -a
  source .env
  set +a
fi

export CHUMP_CASCADE_ENABLED=1
export CHUMP_CLOUD_ONLY=1
# No local slot: cascade uses cloud providers only. Unset so from_env() does not add slot 0.
unset OPENAI_API_BASE

exec "$ROOT/scripts/dev/heartbeat-self-improve.sh"
