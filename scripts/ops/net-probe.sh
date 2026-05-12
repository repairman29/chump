#!/usr/bin/env bash
# net-probe.sh — INFRA-890
# Probes api.anthropic.com reachability and emits ambient events when
# unavailability is detected or resolved.
#
# Usage:
#   scripts/ops/net-probe.sh [--host HOST] [--retries N] [--retry-delay S]
#                            [--dry-run] [--quiet]
#
# Environment:
#   CHUMP_NET_PROBE_DISABLE=1   Skip all probing (opt-out for offline dev).
#   CHUMP_NET_PROBE_HOST        Override default probe host.
#   CHUMP_NET_PROBE_RETRIES     Number of retry attempts (default: 3).
#   CHUMP_NET_PROBE_DELAY_S     Delay between retries in seconds (default: 2).
#
# Exit codes:
#   0  Network reachable (or probe disabled).
#   1  Network unavailable after all retries.
#   2  Usage error.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
AMBIENT="${CHUMP_AMBIENT_LOG:-$REPO_ROOT/.chump-locks/ambient.jsonl}"

HOST="${CHUMP_NET_PROBE_HOST:-api.anthropic.com}"
RETRIES="${CHUMP_NET_PROBE_RETRIES:-3}"
DELAY_S="${CHUMP_NET_PROBE_DELAY_S:-2}"
DRY_RUN=0
QUIET=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --host)        HOST="$2";    shift 2 ;;
        --retries)     RETRIES="$2"; shift 2 ;;
        --retry-delay) DELAY_S="$2"; shift 2 ;;
        --dry-run)     DRY_RUN=1;    shift ;;
        --quiet)       QUIET=1;      shift ;;
        --help|-h)
            sed -n '2,/^$/p' "$0" | sed 's/^# \?//'
            exit 0
            ;;
        *) echo "net-probe.sh: unknown argument: $1" >&2; exit 2 ;;
    esac
done

if [[ "${CHUMP_NET_PROBE_DISABLE:-0}" == "1" ]]; then
    [[ "$QUIET" -eq 0 ]] && echo "[net-probe] CHUMP_NET_PROBE_DISABLE=1 — skipping probe"
    exit 0
fi

SESSION="${SESSION_ID:-$(hostname)-$$}"
ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }

emit() {
    local kind="$1" extra="${2:-}"
    local line
    line=$(printf '{"ts":"%s","kind":"%s","session":"%s","host":"%s"%s}' \
        "$(ts)" "$kind" "$SESSION" "$HOST" "${extra:+,$extra}")
    if [[ "$DRY_RUN" -eq 1 ]]; then
        echo "[net-probe] [dry-run] would emit: $line" >&2
    else
        echo "$line" >> "$AMBIENT" 2>/dev/null || true
    fi
    [[ "$QUIET" -eq 0 ]] && echo "[net-probe] $kind host=$HOST"
}

# Try to reach the host up to RETRIES times.
attempt=0
reached=0
while [[ $attempt -lt $RETRIES ]]; do
    attempt=$(( attempt + 1 ))
    if curl --silent --max-time 5 --head "https://$HOST" >/dev/null 2>&1; then
        reached=1
        break
    fi
    if [[ $attempt -lt $RETRIES ]]; then
        sleep "$DELAY_S"
    fi
done

# State file records the last-known reachability state so we can emit
# network_restored only once when the network comes back.
STATE_FILE="${CHUMP_NET_PROBE_STATE:-$REPO_ROOT/.chump-locks/net-probe-state}"

prev_state="unknown"
if [[ -f "$STATE_FILE" ]]; then
    prev_state=$(cat "$STATE_FILE" 2>/dev/null || echo "unknown")
fi

if [[ "$reached" -eq 1 ]]; then
    if [[ "$DRY_RUN" -eq 0 ]]; then
        echo "reachable" > "$STATE_FILE" 2>/dev/null || true
    fi
    if [[ "$prev_state" == "unreachable" ]]; then
        emit "network_restored"
    elif [[ "$QUIET" -eq 0 ]]; then
        echo "[net-probe] host=$HOST reachable (attempt $attempt/$RETRIES)"
    fi
    exit 0
else
    if [[ "$DRY_RUN" -eq 0 ]]; then
        echo "unreachable" > "$STATE_FILE" 2>/dev/null || true
    fi
    emit "network_unavailable" "\"retries\":$RETRIES"
    exit 1
fi
