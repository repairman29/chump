#!/usr/bin/env bash
# scripts/coord/rpc.sh — INFRA-1119 bash wrapper for the Rust crate impl.
#
# Callable from non-Rust harnesses (per AC #6). Same on-wire envelope as
# the INFRA-1828 ask-* wrappers, so a Rust serve_rpc_n() handler can be
# called by either CLI.
#
# Usage:
#   rpc.sh call <session> <method> <json-args> [timeout_ms]
#   rpc.sh call server-X ask-eta '{"gap_id":"INFRA-1119"}' 5000
#
# Wraps scripts/coord/rpc/_rpc_lib.sh from INFRA-1828 — that file already
# implements the file-backed transport in bash with matching wire format.
# Single canonical entry-point for harness-agnostic callers.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LIB="$REPO_ROOT/scripts/coord/rpc/_rpc_lib.sh"

if [[ ! -r "$LIB" ]]; then
    echo "rpc.sh: missing $LIB (INFRA-1828 should be merged first)" >&2
    exit 1
fi

cmd="${1:-}"
case "$cmd" in
    call)
        shift
        if [[ $# -lt 3 ]]; then
            echo "Usage: rpc.sh call <session> <method> <json-args> [timeout_ms]" >&2
            exit 2
        fi
        target="$1"
        method="$2"
        args="$3"
        timeout_s="${4:-10}"
        # _rpc_lib uses seconds, not ms — convert if caller passes ms-style ints.
        # Heuristic: > 100 = ms, else s. Operators should pass seconds normally.
        if [[ "$timeout_s" -gt 100 ]]; then
            timeout_s=$(( timeout_s / 1000 ))
        fi
        # shellcheck source=./rpc/_rpc_lib.sh disable=SC1091
        source "$LIB"
        _rpc_call "$target" "$method" "$args" "$timeout_s"
        ;;
    -h|--help)
        sed -n '2,/^$/p' "$0" | grep '^#' | sed 's/^# \{0,1\}//'
        exit 0
        ;;
    *)
        echo "rpc.sh: unknown command '$cmd' (want 'call')" >&2
        exit 2
        ;;
esac
