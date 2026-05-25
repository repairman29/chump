#!/usr/bin/env bash
# scripts/coord/fleet-hold-check.sh — INFRA-2004 (THE FLOOR Phase 2)
#
# Worker contract: before a worker claims a new gap (or proceeds to ship),
# it should call this helper. The helper exits non-zero + prints the hold
# details if a cluster-detector fleet-hold is active.
#
# Usage (in worker prelude):
#   if ! bash scripts/coord/fleet-hold-check.sh; then
#       # Pivot to triage / docs / no-op work; do not claim shipping gaps.
#       exit 0
#   fi
#
# CLI for operators:
#   scripts/coord/fleet-hold-check.sh         # exit 0 if no hold, 2 if hold
#   scripts/coord/fleet-hold-check.sh --json  # always exits 0; prints JSON
#   scripts/coord/fleet-hold-check.sh --quiet # no stderr, just exit code
#
# A fleet-hold is written by scripts/coord/cluster-detector.sh when a
# CI-failure cluster fires (per INFRA-1987) and removed when all clusters
# resolve. See docs/strategy/THE_FLOOR.md §2 for the cluster contract.

set -uo pipefail

REPO_ROOT="${CHUMP_REPO:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
HOLD_FILE="${CHUMP_FLEET_HOLD_FILE:-$REPO_ROOT/.chump-locks/fleet-hold.txt}"
FORMAT=text
QUIET=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --json)  FORMAT=json; shift ;;
        --quiet) QUIET=1; shift ;;
        --help|-h)
            sed -n '2,20p' "$0"
            exit 0
            ;;
        *) shift ;;
    esac
done

if [[ ! -f "$HOLD_FILE" ]]; then
    if [[ "$FORMAT" == "json" ]]; then
        echo '{"active":false}'
    elif [[ "$QUIET" -eq 0 ]]; then
        echo "fleet-hold: not active (workers proceed normally)"
    fi
    exit 0
fi

# Hold is active — report + exit non-zero
if [[ "$FORMAT" == "json" ]]; then
    cat "$HOLD_FILE"
    exit 2
fi

if [[ "$QUIET" -eq 0 ]]; then
    echo "fleet-hold: ACTIVE — workers should pivot to triage" >&2
    cat "$HOLD_FILE" >&2
fi
exit 2
