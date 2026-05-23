#!/usr/bin/env bash
# ask-capability.sh — INFRA-1828 / META-061 Layer 2b v0
# Usage: ask-capability.sh <target_session> <capability> [timeout_s]
#
# Asks <target> whether they have the given capability (e.g. "rust",
# "macos", "claude"). Reply: {"has_capability": bool}.
set -euo pipefail

if [[ $# -lt 2 ]]; then
    echo "Usage: ask-capability.sh <target_session> <capability> [timeout_s]" >&2
    exit 2
fi

# shellcheck source=./_rpc_lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/_rpc_lib.sh"

target="$1"
capability="$2"
timeout_s="${3:-$DEFAULT_RPC_TIMEOUT_S}"

_rpc_call "$target" "ask-capability" "{\"capability\":\"$capability\"}" "$timeout_s"
