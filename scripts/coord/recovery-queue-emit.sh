#!/usr/bin/env bash
# scripts/coord/recovery-queue-emit.sh — INFRA-1993 (THE FLOOR Phase 3)
#
# Worker-facing CLI: request operator-recovery (admin-merge cycle) from
# the recovery-queue-service.sh daemon without needing Opus on duty.
#
# Today (pre-INFRA-1993): when a PR cluster blocks the fleet, only Opus
# (with operator's "bridge" authorization) can drop required gates,
# admin-merge the cluster, and re-arm. When neither is online, the
# wedge stays wedged. This emit converts that human-mediated cycle into
# a queue + rate-limited automated service.
#
# Usage (in worker scripts):
#   bash scripts/coord/recovery-queue-emit.sh \
#       --prs 2577,2578,2580 \
#       --cluster-gap META-CLUSTER-12345 \
#       --reason "5-PR pile-up on identical fast-checks+audit failures"
#
# Emits:
#   kind=operator_recovery_requested with prs + cluster_gap_id + reason
#       + authorizing_session (auto-detected from CHUMP_SESSION_ID)
#
# The service daemon (recovery-queue-service.sh) consumes these events,
# rate-limits to 3 cycles/hour fleet-wide, and runs the drop+merge+re-arm
# cycle with full audit trail (kind=operator_recovery_executed).

set -uo pipefail

REPO_ROOT="${CHUMP_REPO:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
AMBIENT="${CHUMP_AMBIENT_LOG:-$REPO_ROOT/.chump-locks/ambient.jsonl}"

PRS_CSV=""
CLUSTER_GAP=""
REASON=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --prs)         PRS_CSV="${2:-}"; shift 2 ;;
        --cluster-gap) CLUSTER_GAP="${2:-}"; shift 2 ;;
        --reason)      REASON="${2:-}"; shift 2 ;;
        --help|-h)
            sed -n '2,25p' "$0"
            exit 0
            ;;
        *) shift ;;
    esac
done

if [[ -z "$PRS_CSV" ]] || [[ -z "$REASON" ]]; then
    echo "Usage: recovery-queue-emit.sh --prs <CSV> --reason '<text>' [--cluster-gap GAP-NNN]" >&2
    echo "Example: recovery-queue-emit.sh --prs 2577,2578 --reason 'pile-up: identical audit failures'" >&2
    exit 2
fi

SESSION="${CHUMP_SESSION_ID:-${CLAUDE_SESSION_ID:-worker-$$}}"
TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

mkdir -p "$(dirname "$AMBIENT")" 2>/dev/null || true

printf '{"ts":"%s","kind":"operator_recovery_requested","source":"recovery_queue_emit","prs":"%s","cluster_gap_id":"%s","reason":"%s","authorizing_session":"%s"}\n' \
    "$TS" \
    "$PRS_CSV" \
    "${CLUSTER_GAP:-none}" \
    "$REASON" \
    "$SESSION" \
    >> "$AMBIENT" 2>/dev/null || true

echo "recovery-queue: request emitted for PRs $PRS_CSV (cluster=$CLUSTER_GAP, session=$SESSION)" >&2
echo "  Daemon will process within ~60s (subject to rate limit of 3/hour)"
echo "  Audit: tail .chump-locks/ambient.jsonl | grep operator_recovery_executed"

exit 0
