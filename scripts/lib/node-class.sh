#!/usr/bin/env bash
# ZERO-WASTE-153: node capacity class. Sourced by the pre-commit hook and run-fleet.sh.
#   CHUMP_NODE_CLASS=small|normal overrides; else ~/.chump/node-class; else auto
#   (small when MemTotal <= 8 GiB). CHUMP_RUST_LANES = max concurrent Rust lanes
#   on a small node (default 2).
chump_node_class() {
    local c="${CHUMP_NODE_CLASS:-}"
    [ -z "$c" ] && [ -f "$HOME/.chump/node-class" ] && c="$(tr -d '[:space:]' < "$HOME/.chump/node-class")"
    if [ -z "$c" ]; then
        local kb
        kb="$(awk '/^MemTotal:/{print $2}' /proc/meminfo 2>/dev/null)"
        if [ -n "$kb" ] && [ "$kb" -le 8500000 ]; then c=small; else c=normal; fi
    fi
    echo "$c"
}
chump_rust_lanes() { echo "${CHUMP_RUST_LANES:-2}"; }
