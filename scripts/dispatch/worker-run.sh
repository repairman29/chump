#!/usr/bin/env bash
# RESILIENT-283: headless-native worker runner. One worker.sh loop, no tmux dashboard.
# Usage: worker-run.sh <AGENT_ID>.  systemd's minimal env lacks HOME/PATH/USER — set them.
export HOME="${HOME:-/root}"
export USER="${USER:-root}"
export PATH="/root/.cargo/bin:/root/.local/bin:/root/bin:/usr/local/bin:/usr/bin:/bin"
set -a; source /root/.chump/providers.env 2>/dev/null; set +a
export CHUMP_AUTH_MODE=oauth CHUMP_REPO=/root/Projects/chump IS_SANDBOX=1
export FLEET_MODEL="${FLEET_MODEL:-sonnet}" TERM="${TERM:-dumb}"
export AGENT_ID="${1:?need AGENT_ID}" FLEET_SESSION="${FLEET_SESSION:-ops}"
cd /root/Projects/chump || exit 1
exec bash scripts/dispatch/worker.sh
