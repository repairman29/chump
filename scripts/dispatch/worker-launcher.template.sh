#!/usr/bin/env bash
# worker-launcher.template.sh — RESILIENT-1099: tracked, node-neutral worker
# launcher template.
#
# Before this file existed, every node ran a hand-deployed, git-UNTRACKED
# launcher (e.g. ~/node1-worker-run.sh) that baked in PATH, WORKER_SKILLS,
# and FLEET_DOMAIN_FILTER by hand per node. That drift (cuphead's launcher
# hardcoded FLEET_DOMAIN_FILTER=RESILIENT, mugman's hardcoded
# FLEET_DOMAIN_FILTER=EFFECTIVE,CREDIBLE) is the exact class that froze the
# fleet for ~15h on 2026-09-08 (see scripts/setup/worker-policy.env). Nothing
# in git described the launcher, so nothing could review, reproduce, or heal
# it, and a fresh node had no one-command way to get a correct one.
#
# This template is rendered by render_worker_launcher() in
# scripts/setup/chump-node-install.sh — node identity (AGENT_ID /
# WORKER_MACHINE / FLEET_SESSION / WORKER_SKILLS / FLEET_DOMAIN_FILTER /
# REPO_ROOT) is the ONLY per-node input. Self-heal policy and model-routing
# come from the tracked scripts/setup/worker-policy.env and
# scripts/setup/model-escalation-ladder.env, which worker.sh sources itself
# — so this template does NOT duplicate that policy, it only supplies
# identity. Never hand-edit a rendered launcher; edit THIS template (or the
# policy files above) and re-render via `chump-node-install.sh
# --reconcile-organs-only`, or the drift comes back on the next re-provision.
#
# Placeholders (substituted at render time — never present in a live launcher):
#   __AGENT_ID__            per-node agent id, e.g. "node1-worker"
#   __WORKER_MACHINE__      machine label for A2A / capability routing
#   __FLEET_SESSION__       session tag used in logs / lease naming
#   __WORKER_SKILLS__       comma-separated capability tags (may be empty)
#   __FLEET_DOMAIN_FILTER__ comma-separated domain filter (may be empty = any)
#   __REPO_ROOT__           absolute path to this node's chump checkout
set -a
[ -f "$HOME/.chump/providers.env" ] && source "$HOME/.chump/providers.env"
set +a
export PATH="$HOME/.cargo/bin:__REPO_ROOT__/target/release:/usr/local/bin:/usr/bin:/bin"
export TMPDIR="${TMPDIR:-$HOME/tmp}"
mkdir -p "$TMPDIR"

export CHUMP_AUTH_MODE="${CHUMP_AUTH_MODE:-oauth}"
export AGENT_ID="__AGENT_ID__"
export WORKER_MACHINE="__WORKER_MACHINE__"
export FLEET_SESSION="__FLEET_SESSION__"
export WORKER_SKILLS="__WORKER_SKILLS__"
export FLEET_DOMAIN_FILTER="__FLEET_DOMAIN_FILTER__"
export FLEET_BACKEND="${FLEET_BACKEND:-claude}"
export FLEET_PRIORITY_FILTER="${FLEET_PRIORITY_FILTER:-P0,P1,P2}"
export FLEET_EFFORT_FILTER="${FLEET_EFFORT_FILTER:-xs,s,m}"

cd "__REPO_ROOT__" || exit 1
exec bash scripts/dispatch/worker.sh
