#!/data/data/com.termux/files/usr/bin/env bash
# nats-bridge.sh — RESILIENT-376: durable NATS-KV bridge for an off-cluster
# fleet node (the Pixel 8 Pro / aarch64 Termux).
#
# WHY: the shared claim queue is NATS-KV on CJ, but CJ's nats-server binds
# 127.0.0.1:4222 (localhost-only, no cross-machine auth). A node that is not
# CJ therefore cannot reach the coordinator directly. This organ holds a
# durable ssh port-forward (Pixel localhost:4222 -> CJ 127.0.0.1:4222) so
# `chump gap claim` (CoordClient::try_claim_gap) can lease gaps atomically
# across the fleet. RESILIENT-376's one-shot proof used a hand-run tunnel;
# this makes it a supervised organ.
#
# DURABILITY: this script is a single foreground `ssh -N`. When the link
# drops (ServerAliveInterval detects a dead peer, or the forward fails),
# ssh EXITS and the runit runsv that supervises this organ respawns it
# within seconds. runsvdir is started by Termux:Boot, so the bridge also
# survives a reboot. ExitOnForwardFailure=yes means we never sit "up" with a
# dead forward (fail loud, let runsv restart).
set -uo pipefail

# Upstream NATS host (CJ). Resolvable via the node's ssh config / known hosts.
CJ_SSH_TARGET="${CHUMP_NATS_SSH_TARGET:-jeff@closetjunky}"
# Local port the chump binary connects to (matches CHUMP_NATS_URL).
LOCAL_PORT="${CHUMP_NATS_LOCAL_PORT:-4222}"
# Remote bind on CJ (its localhost-only nats-server).
REMOTE_HOSTPORT="${CHUMP_NATS_REMOTE_HOSTPORT:-127.0.0.1:4222}"

# If something else already holds the port (e.g. a manual tunnel), don't fight
# it — exit so runsv retries shortly; the existing listener keeps the node joined.
if (ss -tln 2>/dev/null || netstat -tln 2>/dev/null) | grep -q ":${LOCAL_PORT}[[:space:]]"; then
  echo "[nats-bridge] port ${LOCAL_PORT} already listening; deferring (runsv will retry)"
  sleep 30
  exit 0
fi

echo "[nats-bridge] $(date -u +%FT%TZ) opening ${LOCAL_PORT} -> ${CJ_SSH_TARGET}:${REMOTE_HOSTPORT}"

# -N: no remote command (forward only). BatchMode: never prompt (headless).
# ExitOnForwardFailure: die if the forward can't be established.
# ServerAlive*: detect a dead peer in ~60s and exit so runsv restarts us.
exec ssh -N \
  -o BatchMode=yes \
  -o StrictHostKeyChecking=accept-new \
  -o ExitOnForwardFailure=yes \
  -o ServerAliveInterval=20 \
  -o ServerAliveCountMax=3 \
  -o ConnectTimeout=15 \
  -L "${LOCAL_PORT}:${REMOTE_HOSTPORT}" \
  "${CJ_SSH_TARGET}"
