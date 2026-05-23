#!/usr/bin/env bash
# ask-handoff.sh — INFRA-1828 / META-061 Layer 2b v0
# Usage: ask-handoff.sh <target_session> <gap_id> [reason] [timeout_s]
#
# Asks <target> to accept handoff of <gap_id>. Reply: {"accepted": bool,
# "reason": str}.
set -euo pipefail

if [[ $# -lt 2 ]]; then
    echo "Usage: ask-handoff.sh <target_session> <gap_id> [reason] [timeout_s]" >&2
    exit 2
fi

# shellcheck source=./_rpc_lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/_rpc_lib.sh"

target="$1"
gap_id="$2"
reason="${3:-}"
timeout_s="${4:-$DEFAULT_RPC_TIMEOUT_S}"

args=$(python3 -c "
import json, sys
print(json.dumps({'gap_id': sys.argv[1], 'reason': sys.argv[2]}, separators=(',', ':')))
" "$gap_id" "$reason")

_rpc_call "$target" "ask-handoff" "$args" "$timeout_s"
