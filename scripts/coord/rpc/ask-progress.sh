#!/usr/bin/env bash
# ask-progress.sh — INFRA-1828 / META-061 Layer 2b v0
# Usage: ask-progress.sh <target_session> <gap_id> [timeout_s]
#
# Asks <target> for their progress on <gap_id>. Reply:
# {"pct_complete": int, "last_commit_sha": str}.
set -euo pipefail

if [[ $# -lt 2 ]]; then
    echo "Usage: ask-progress.sh <target_session> <gap_id> [timeout_s]" >&2
    exit 2
fi

# shellcheck source=./_rpc_lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/_rpc_lib.sh"

target="$1"
gap_id="$2"
timeout_s="${3:-$DEFAULT_RPC_TIMEOUT_S}"

_rpc_call "$target" "ask-progress" "{\"gap_id\":\"$gap_id\"}" "$timeout_s"
