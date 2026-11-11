#!/usr/bin/env bash
# node-id.sh — INFRA-8059: stable node identifier for attribution stamps
# (commit trailers, ambient `host` field). Override with CHUMP_NODE_ID.
chump_node_id() {
    local n="${CHUMP_NODE_ID:-}"
    [[ -z "$n" ]] && n="$(hostname -s 2>/dev/null || hostname 2>/dev/null || true)"
    [[ -z "$n" ]] && n="unknown"
    printf '%s' "$n" | tr -c 'A-Za-z0-9._-' '_'
}
