#!/usr/bin/env bash
# scripts/coord/refresh-claim-heartbeat.sh — INFRA-1236
#
# Bumps the `heartbeat_at` field of a claim-*.json lease to "now". Pairs
# with the heartbeat-liveness check in scripts/ops/stale-gap-lock-reaper.sh
# (INFRA-1236): a lease whose heartbeat_at is fresh (< CHUMP_LEASE_HEARTBEAT_TTL_S,
# default 600s) is treated as alive even if the PID embedded in session_id
# is gone.
#
# Use this from any non-Rust caller that holds a lease and wants to keep
# it alive across long operations. Recommended cadence: every 60-300s.
#
# Usage:
#   scripts/coord/refresh-claim-heartbeat.sh <session_id>          # one-shot
#   scripts/coord/refresh-claim-heartbeat.sh <session_id> --watch  # loop every 60s
#   scripts/coord/refresh-claim-heartbeat.sh <gap_id> --by-gap     # find the lease by gap
#
# Env:
#   CHUMP_LOCK_DIR — override default .chump-locks dir
#   CHUMP_HEARTBEAT_INTERVAL_S — watch-mode tick (default 60)
#
# Exit codes:
#   0 — heartbeat written
#   1 — lease file not found
#   2 — JSON write failed
#   3 — bad invocation

set -euo pipefail

if [[ $# -lt 1 ]]; then
    echo "usage: $0 <session_id|gap_id> [--watch] [--by-gap]" >&2
    exit 3
fi

ID="$1"
shift
WATCH=false
BY_GAP=false
for arg in "$@"; do
    case "$arg" in
        --watch) WATCH=true ;;
        --by-gap) BY_GAP=true ;;
        *) echo "unknown flag: $arg" >&2; exit 3 ;;
    esac
done

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
LOCK_DIR="${CHUMP_LOCK_DIR:-$REPO_ROOT/.chump-locks}"
INTERVAL="${CHUMP_HEARTBEAT_INTERVAL_S:-60}"

resolve_lease_path() {
    local key="$1"
    if [[ "$BY_GAP" == "true" ]]; then
        # Find newest claim-*.json whose gap_id matches.
        local found=""
        local newest_mtime=0
        for f in "$LOCK_DIR"/claim-*.json; do
            [[ -f "$f" ]] || continue
            local gid
            gid="$(python3 -c "
import json
try: print(json.load(open('$f')).get('gap_id',''))
except Exception: print('')
" 2>/dev/null)"
            if [[ "$gid" == "$key" ]]; then
                local mt
                mt="$(stat -f %m "$f" 2>/dev/null || stat -c %Y "$f" 2>/dev/null || echo 0)"
                if [[ "$mt" -gt "$newest_mtime" ]]; then
                    newest_mtime="$mt"
                    found="$f"
                fi
            fi
        done
        printf '%s' "$found"
    else
        printf '%s' "$LOCK_DIR/${key}.json"
    fi
}

bump_one() {
    local lease="$1"
    [[ -f "$lease" ]] || { echo "lease not found: $lease" >&2; return 1; }
    local now
    now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    python3 - "$lease" "$now" <<'PY' || return 2
import json, sys
path, now = sys.argv[1], sys.argv[2]
with open(path) as f:
    d = json.load(f)
d['heartbeat_at'] = now
tmp = path + '.tmp'
with open(tmp, 'w') as f:
    json.dump(d, f, indent=2)
    f.write('\n')
import os
os.replace(tmp, path)
PY
}

lease_path="$(resolve_lease_path "$ID")"
if [[ -z "$lease_path" ]]; then
    echo "no lease matched: $ID" >&2
    exit 1
fi

if [[ "$WATCH" == "true" ]]; then
    echo "[heartbeat] watching $(basename "$lease_path") every ${INTERVAL}s — Ctrl+C to stop"
    while true; do
        if ! bump_one "$lease_path"; then
            echo "[heartbeat] lease vanished — exiting" >&2
            exit 1
        fi
        sleep "$INTERVAL"
    done
else
    bump_one "$lease_path"
    echo "[heartbeat] refreshed: $(basename "$lease_path")"
fi
