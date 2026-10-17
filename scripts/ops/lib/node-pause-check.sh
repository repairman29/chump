#!/usr/bin/env bash
# scripts/ops/lib/node-pause-check.sh — RESILIENT-1614
#
# Shared check function for all work organs. Returns 0 (paused) or 1 (not paused).
# When paused, the caller should:
#   1. Emit kind=organ_skipped_paused to ambient.jsonl
#   2. Exit 0 (not an error — a deliberate pause is not a failure)

_node_pause_check_is_paused() {
    local state_dir="${CHUMP_STATE_DIR:-${HOME:-/root}/.chump}"
    local node_env="$state_dir/node.env"

    # Check the sentinel file first (fastest path).
    [[ -f "$state_dir/fleet-paused" ]] && return 0

    # Check node.env for CHUMP_NODE_MODE=paused or CHUMP_NODE_WORK_ENABLED=0.
    if [[ -f "$node_env" ]]; then
        # Extract CHUMP_NODE_MODE.
        local mode
        mode="$(grep -E '^(export )?CHUMP_NODE_MODE=' "$node_env" 2>/dev/null | tail -1 | sed -E 's/^(export )?CHUMP_NODE_MODE=//; s/^"(.*)"$/\1/')"
        [[ "$mode" == "paused" ]] && return 0

        # Check CHUMP_NODE_WORK_ENABLED as a fallback.
        local work_enabled
        work_enabled="$(grep -E '^(export )?CHUMP_NODE_WORK_ENABLED=' "$node_env" 2>/dev/null | tail -1 | sed -E 's/^(export )?CHUMP_NODE_WORK_ENABLED=//; s/^"(.*)"$/\1/')"
        [[ "$work_enabled" == "0" ]] && return 0
    fi

    return 1
}

# Emit kind=organ_skipped_paused to the ambient stream.
_node_pause_emit_skipped() {
    local ambient_path="${NODE_AMBIENT:-}"
    if [[ -z "$ambient_path" ]]; then
        local state_dir="${CHUMP_STATE_DIR:-${HOME:-/root}/.chump}"
        ambient_path="$state_dir/../.chump-locks/ambient.jsonl"
    fi

    local ts
    ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    local event="{\"ts\":\"$ts\",\"kind\":\"organ_skipped_paused\"}"

    if [[ -d "$(dirname "$ambient_path")" ]]; then
        printf '%s\n' "$event" >> "$ambient_path" 2>/dev/null || true
    fi
}
