#!/usr/bin/env bash
# RESILIENT-283 / INFRA-3659: headless-native worker runner. One worker.sh loop, no tmux dashboard.
#
# Node-agnostic by construction (INFRA-3659): derives its own repo root from
# its own on-disk location instead of a hardcoded /root path, so the SAME
# templated unit (chump-worker@.service) runs on ANY owned node (root on one
# box, jeff on CJ) — no more hand-placed cj-worker*-run.sh snowflakes with a
# different baked-in path per node.
#
# Usage: worker-run.sh <AGENT_ID>.  systemd's minimal env lacks HOME/PATH/USER — set them.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
export HOME="${HOME:-/root}"
export USER="${USER:-root}"
export PATH="$HOME/.cargo/bin:$HOME/.local/bin:$HOME/bin:/usr/local/bin:/usr/bin:/bin"
set -a; source "$HOME/.chump/providers.env" 2>/dev/null; set +a
export CHUMP_AUTH_MODE=oauth CHUMP_REPO="${CHUMP_REPO:-$REPO_ROOT}" IS_SANDBOX=1
export FLEET_MODEL="${FLEET_MODEL:-sonnet}" TERM="${TERM:-dumb}"
export AGENT_ID="${1:?need AGENT_ID}" FLEET_SESSION="${FLEET_SESSION:-ops}"

# INFRA-3659: cap aggregate cargo parallelism to this node's core count
# instead of a hand-edited ~/.cargo/config.toml jobs=1 override (the
# 2026-08-22 CJ incident: 4 cores, ~14 workers x CARGO_BUILD_JOBS=4 default =
# ~56 concurrent rustc threads -> swap thrash, 30-45min/gap, unverified_ship).
# Divide nproc across the CURRENTLY active worker-unit count (this instance
# included) so the aggregate stays <= nproc without any node needing a
# hand-set override. Explicit CARGO_BUILD_JOBS in the environment still wins.
_cores="$(nproc 2>/dev/null || echo 1)"
_workers_up="$(systemctl list-units 'chump-worker@*.service' 'chump-cj-worker*' --state=active --no-legend 2>/dev/null | grep -c '\.service')"
[ "${_workers_up:-0}" -lt 1 ] && _workers_up=1
_auto_jobs=$(( _cores / _workers_up ))
[ "$_auto_jobs" -lt 1 ] && _auto_jobs=1
export CARGO_BUILD_JOBS="${CARGO_BUILD_JOBS:-$_auto_jobs}"

cd "$CHUMP_REPO" || exit 1
exec bash scripts/dispatch/worker.sh
