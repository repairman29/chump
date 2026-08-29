#!/usr/bin/env bash
# reap-stale-bot-merge-health.sh — INFRA-1531
#
# CLI wrapper around lib/stale-bot-merge-health.sh's reap_stale_bot_merge_health,
# called by `chump fleet up` on startup to clear dead-pid .health files before
# they can trigger a false bot_merge_hung ALERT.
#
# Usage: reap-stale-bot-merge-health.sh <lock_dir> [emit_ambient=0|1]

set -euo pipefail

LOCK_DIR="${1:-.chump-locks}"
EMIT_AMBIENT="${2:-1}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/stale-bot-merge-health.sh
source "$SCRIPT_DIR/lib/stale-bot-merge-health.sh"

reap_stale_bot_merge_health "$LOCK_DIR" "$EMIT_AMBIENT"
