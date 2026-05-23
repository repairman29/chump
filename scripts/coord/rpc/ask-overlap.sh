#!/usr/bin/env bash
# ask-overlap.sh — INFRA-1828 / META-061 Layer 2b v0
# Usage: ask-overlap.sh <target_session> <paths_csv> [timeout_s]
#
# Asks <target> which of the given paths are currently in their active
# leases. Reply shape: {"held_paths": ["path1", "path2"]}.
set -euo pipefail

if [[ $# -lt 2 ]]; then
    echo "Usage: ask-overlap.sh <target_session> <paths_csv> [timeout_s]" >&2
    exit 2
fi

# shellcheck source=./_rpc_lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/_rpc_lib.sh"

target="$1"
paths_csv="$2"
timeout_s="${3:-$DEFAULT_RPC_TIMEOUT_S}"

args=$(python3 -c "
import json, sys
paths = [p.strip() for p in sys.argv[1].split(',') if p.strip()]
print(json.dumps({'paths': paths}, separators=(',', ':')))
" "$paths_csv")

_rpc_call "$target" "ask-overlap" "$args" "$timeout_s"
