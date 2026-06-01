#!/usr/bin/env bash
# META-271 / INFRA-2367 — quick artifact-dump from the inventory DB.
#
# Use case: ops dashboards / harvesters that want a flat path list
# (one artifact per line) filtered by class + activation_state, without
# linking against rusqlite.
#
# Usage:
#   collect-artifacts.sh                                # all artifacts
#   collect-artifacts.sh --class shell-script           # one class
#   collect-artifacts.sh --activation orphan            # orphans only
#   collect-artifacts.sh --class rust-mod --activation dormant
#
# Exits 0 even on empty result (consistent with `git ls-files`).
set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
INV_DB="${CHUMP_INVENTORY_DB:-$REPO_ROOT/.chump/inventory.db}"

if [[ ! -f "$INV_DB" ]]; then
    echo "[collect-artifacts] inventory DB not found at $INV_DB" >&2
    echo "[collect-artifacts] run: chump inventory rebuild" >&2
    exit 1
fi

class=""
activation=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --class)
            shift
            class="$1"
            ;;
        --activation)
            shift
            activation="$1"
            ;;
        --help | -h)
            echo "Usage: $0 [--class CLASS] [--activation STATE]"
            exit 0
            ;;
        *)
            echo "[collect-artifacts] unknown flag: $1" >&2
            exit 2
            ;;
    esac
    shift
done

sql="SELECT path FROM artifact_index WHERE 1=1"
if [[ -n "$class" ]]; then
    sql="$sql AND class = '$class'"
fi
if [[ -n "$activation" ]]; then
    sql="$sql AND activation_state = '$activation'"
fi
sql="$sql ORDER BY path;"

sqlite3 "$INV_DB" "$sql"
