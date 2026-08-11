#!/usr/bin/env bash
# shellcheck disable=SC1091  # lib/ dynamic sources
# scripts/coord/merge-sla-scorecard.sh — RESILIENT-302
#
# WHY THIS EXISTS. #3621 rotted 18h unmerged and nothing on the board owned
# that as a violation — no goal, no threshold, no page. Operator decision
# (Jeff, 2026-08-11): HARD THRESHOLD 30 MINUTES. Any open PR unmerged >30m
# must have (a) merged, (b) a named owner actively working it (an active
# claim lease for the gap the PR closes), or (c) an escalation already sent
# to the operator — otherwise it is a board BREACH.
#
# Board cadence is 15m (docs/process/SCHEDULING_LAYERS.md daemon pattern via
# `chump cron install`), so a fresh 30m breach is caught within one cycle.
#
# Usage:
#   scripts/coord/merge-sla-scorecard.sh             # dry-run, prints scorecard
#   scripts/coord/merge-sla-scorecard.sh --apply      # emits sla_breach + pages Discord
#
# Emits kind=sla_breach to ambient.jsonl for every PR breaching the
# threshold with no owner/escalation. Routes to the operator via
# notify-operator.sh (Discord DM), gated by the standard escalation
# registry (RESILIENT-274) so a re-breaching PR doesn't spam the phone —
# CHUMP_SLA_BREACH_RESEND_COOLDOWN_S (default 1800s = 30m) throttles resends.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd -P)"
LOCK_DIR="$REPO_ROOT/.chump-locks"
BREACH_SENT_DIR="$LOCK_DIR/.sla-breach-sent"
mkdir -p "$BREACH_SENT_DIR" 2>/dev/null || true

# shellcheck source=lib/github_cache.sh
[[ -f "${SCRIPT_DIR}/lib/github_cache.sh" ]] && source "${SCRIPT_DIR}/lib/github_cache.sh"
# shellcheck source=lib/ambient-write.sh
source "${SCRIPT_DIR}/lib/ambient-write.sh"
# shellcheck source=lib/notify-operator.sh
[[ -f "${SCRIPT_DIR}/lib/notify-operator.sh" ]] && source "${SCRIPT_DIR}/lib/notify-operator.sh"

THRESHOLD_S="${CHUMP_SLA_MERGE_THRESHOLD_S:-1800}"                    # 30m, hard threshold
RESEND_COOLDOWN_S="${CHUMP_SLA_BREACH_RESEND_COOLDOWN_S:-1800}"       # 30m

APPLY=0
while [ $# -gt 0 ]; do
    case "$1" in
        --apply) APPLY=1; shift ;;
        --threshold) THRESHOLD_S="$2"; shift 2 ;;
        --cooldown) RESEND_COOLDOWN_S="$2"; shift 2 ;;
        -h|--help) sed -n '2,25p' "$0" | sed 's/^# \?//'; exit 0 ;;
        *) echo "[merge-sla-scorecard] unknown arg: $1" >&2; exit 2 ;;
    esac
done

command -v gh >/dev/null 2>&1 || { echo "[merge-sla-scorecard] gh missing; skip"; exit 0; }
declare -F cache_query_open_prs >/dev/null 2>&1 || { echo "[merge-sla-scorecard] github_cache.sh lib missing; skip" >&2; exit 1; }

# INFRA-1274: cache-first — no raw `gh api` here. cache_query_open_prs reads
# .chump/github_cache.db (fed by the webhook receiver); cache_lookup_pr below
# resolves per-PR created_at from the same cache, only falling back to a REST
# call (inside lib/, exempt from the hot-path lint gate) on a cache miss.
prs_tmp="$(mktemp)"
trap 'rm -f "$prs_tmp"' EXIT
cache_query_open_prs > "$prs_tmp" 2>/dev/null

if [ ! -s "$prs_tmp" ]; then
    echo "[merge-sla-scorecard] no open PRs — 0 breaches"
    exit 0
fi

now_epoch="$(date +%s)"
open_count=0
breach_count=0
owned_count=0
escalated_count=0
skipped_dedup=0

while IFS=$'\t' read -r pr_num title head_ref; do
    [ -z "$pr_num" ] && continue
    open_count=$((open_count + 1))

    pr_payload="$(cache_lookup_pr "$pr_num" 2>/dev/null)"
    created_epoch="$(python3 -c "
from datetime import datetime
import json, sys
try:
    v = json.loads(sys.argv[1]).get('created_at', '').replace('Z','+00:00')
    print(int(datetime.fromisoformat(v).timestamp()))
except Exception: print(0)
" "$pr_payload" 2>/dev/null || echo 0)"
    [ "$created_epoch" = "0" ] && continue
    age_s=$(( now_epoch - created_epoch ))
    [ "$age_s" -lt "$THRESHOLD_S" ] && continue

    gap_id="$(echo "$title" | grep -oE '[A-Z]+-[0-9]+' | head -1)"

    # Owner check: an active, unexpired claim lease for the gap this PR closes.
    owner=""
    if [ -n "$gap_id" ]; then
        claim_lease="$(ls "$LOCK_DIR"/claim-"$(echo "$gap_id" | tr '[:upper:]' '[:lower:]')"-*.json 2>/dev/null | head -1 || true)"
        if [ -n "$claim_lease" ]; then
            owner="$(python3 -c "
import json, sys
try: print(json.load(open(sys.argv[1])).get('session_id',''))
except Exception: print('')
" "$claim_lease" 2>/dev/null || echo "")"
        fi
    fi
    if [ -n "$owner" ]; then
        owned_count=$((owned_count + 1))
        echo "[merge-sla-scorecard] OWNED #$pr_num ($gap_id) age=${age_s}s owner=$owner"
        continue
    fi

    # Escalation check: dedup stamp within cooldown means we already paged
    # the operator for this PR — count it, don't re-page every cycle.
    stamp="$BREACH_SENT_DIR/$pr_num.ts"
    already_escalated=0
    if [ -f "$stamp" ]; then
        stamp_ts="$(cat "$stamp" 2>/dev/null || echo 0)"
        if [ "$stamp_ts" -gt 0 ] && [ $(( now_epoch - stamp_ts )) -lt "$RESEND_COOLDOWN_S" ]; then
            already_escalated=1
        fi
    fi

    breach_count=$((breach_count + 1))
    reason="PR #$pr_num ($head_ref) open ${age_s}s (> ${THRESHOLD_S}s SLA) with no owner."
    [ -n "$gap_id" ] && reason="$reason gap=$gap_id."

    if [ "$already_escalated" -eq 1 ]; then
        skipped_dedup=$((skipped_dedup + 1))
        escalated_count=$((escalated_count + 1))
        echo "[merge-sla-scorecard] BREACH #$pr_num already escalated within cooldown — $reason"
        continue
    fi

    if [ "$APPLY" -eq 1 ]; then
        _ambient_write "$LOCK_DIR/ambient.jsonl" \
            "$(printf '{"ts":"%s","kind":"sla_breach","pr":%s,"age_s":%d,"threshold_s":%d,"gap":"%s"}' \
                "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$pr_num" "$age_s" "$THRESHOLD_S" "${gap_id:-}")"
        if declare -F notify_operator >/dev/null 2>&1; then
            CHUMP_NOTIFY_KIND="sla_breach" CHUMP_NOTIFY_SEVERITY="halt" \
                notify_operator "MERGE-SLA BREACH: $reason" >/dev/null 2>&1 || true
        fi
        printf '%s' "$now_epoch" > "$stamp"
        escalated_count=$((escalated_count + 1))
        echo "[merge-sla-scorecard] BREACH #$pr_num — $reason (emitted + paged)"
    else
        echo "[merge-sla-scorecard] WOULD BREACH #$pr_num — $reason"
    fi
done < "$prs_tmp"

echo "[merge-sla-scorecard] open=$open_count breaches=$breach_count owned=$owned_count escalated=$escalated_count skipped-dedup=$skipped_dedup threshold_s=$THRESHOLD_S"
exit 0
