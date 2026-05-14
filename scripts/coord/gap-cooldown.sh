#!/usr/bin/env bash
# scripts/coord/gap-cooldown.sh — INFRA-1220
#
# Operator/automation CLI over scripts/coord/lib/gap-cooldown.sh.
#
# Usage:
#   gap-cooldown.sh stamp <GAP-ID> [--pr N] [--reason "..."]
#       Mark this gap as cooling-down (refused for new claims until window
#       elapses; default 1 h). Typically called by an orphan-pr-closer / the
#       PR-close webhook after closing a zombie/dirty PR.
#
#   gap-cooldown.sh clear <GAP-ID> --reason "..."
#       Operator override: remove the cooldown. Reason is required (audit).
#
#   gap-cooldown.sh status <GAP-ID>
#       Print the cooldown state (or nothing if inactive).
#
#   gap-cooldown.sh active <GAP-ID>
#       Exit 0 if cooldown is active, 1 if clear (script-friendly).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/gap-cooldown.sh"

usage() { sed -n '3,21p' "$0" | sed 's/^# \?//'; }

cmd="${1:-}"
shift || true

case "$cmd" in
    stamp)
        gap=""
        pr=""
        reason=""
        while [ $# -gt 0 ]; do
            case "$1" in
                --pr) pr="$2"; shift 2 ;;
                --reason) reason="$2"; shift 2 ;;
                -*) echo "stamp: unknown flag $1" >&2; exit 2 ;;
                *)  [ -z "$gap" ] && gap="$1" && shift || { echo "stamp: extra arg $1" >&2; exit 2; } ;;
            esac
        done
        [ -z "$gap" ] && { usage; exit 2; }
        gap_cooldown_stamp "$gap" "$pr" "$reason"
        echo "[gap-cooldown] stamped $gap (pr=$pr reason=$reason)"
        ;;
    clear)
        gap=""
        reason=""
        while [ $# -gt 0 ]; do
            case "$1" in
                --reason) reason="$2"; shift 2 ;;
                -*) echo "clear: unknown flag $1" >&2; exit 2 ;;
                *)  [ -z "$gap" ] && gap="$1" && shift || { echo "clear: extra arg $1" >&2; exit 2; } ;;
            esac
        done
        [ -z "$gap" ] && { usage; exit 2; }
        [ -z "$reason" ] && { echo "clear: --reason is required (audit)" >&2; exit 2; }
        gap_cooldown_clear "$gap" "$reason"
        echo "[gap-cooldown] cleared $gap (reason: $reason)"
        ;;
    status)
        gap="${1:-}"
        [ -z "$gap" ] && { usage; exit 2; }
        gap_cooldown_status "$gap"
        ;;
    active)
        gap="${1:-}"
        [ -z "$gap" ] && { usage; exit 2; }
        if gap_cooldown_active "$gap"; then exit 0; else exit 1; fi
        ;;
    -h|--help|"")
        usage; exit 0
        ;;
    *)
        echo "unknown subcommand: $cmd" >&2
        usage; exit 2
        ;;
esac
