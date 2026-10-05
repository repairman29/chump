#!/usr/bin/env bash
# shellcheck disable=SC1091  # lib/ dynamic sources
# scripts/coord/merge-sla-scorecard.sh — RESILIENT-302
#
# WHY THIS EXISTS. #3621 rotted 18h unmerged and nothing on the board owned
# that as a violation — no goal, no threshold, no page. Operator decision
# (Jeff, 2026-08-11): open PRs unmerged past the breach threshold must have
# (a) merged, (b) a named owner actively working it (an active claim lease
# for the gap the PR closes), or (c) an escalation already sent to the
# operator — otherwise it is a board BREACH.
#
# Board cadence is 15m (docs/process/SCHEDULING_LAYERS.md daemon pattern via
# `chump cron install`), so a fresh breach is caught within one cycle.
#
# RATCHET NOTE (INFRA-3592). The threshold starts loose (60m) and tightens
# as the tail improves: 60 -> 45 -> 30, moving down a notch once p90 (see
# scorecard output below) settles comfortably under the next line. Benchmark
# 2026-08-11: p50=14m p90=299m — p90 is nowhere near 60m yet, so 60m is the
# honest starting line rather than a threshold nothing can ever hit. Tighten
# via CHUMP_SLA_BREACH_MINUTES as the p90 trend improves; don't hand-edit the
# default without a fresh benchmark to justify the new line.
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

# shellcheck source=lib/github.sh
source "${SCRIPT_DIR}/lib/github.sh"
# shellcheck source=lib/github_cache.sh
[[ -f "${SCRIPT_DIR}/lib/github_cache.sh" ]] && source "${SCRIPT_DIR}/lib/github_cache.sh"
# shellcheck source=lib/ambient-write.sh
source "${SCRIPT_DIR}/lib/ambient-write.sh"
# shellcheck source=lib/notify-operator.sh
[[ -f "${SCRIPT_DIR}/lib/notify-operator.sh" ]] && source "${SCRIPT_DIR}/lib/notify-operator.sh"

THRESHOLD_MINUTES="${CHUMP_SLA_BREACH_MINUTES:-60}"                   # ratchet: 60 -> 45 -> 30
THRESHOLD_S="${CHUMP_SLA_MERGE_THRESHOLD_S:-$((THRESHOLD_MINUTES * 60))}"
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
CHUMP_GH_SCRIPT="merge-sla-scorecard.sh"
# INFRA-2464: cache-first repo nwo (disk-memoized 24h TTL via _cache_repo_nwo)
# instead of a raw `gh repo view` call every tick — this daemon runs on a 15m
# cadence (see header), so uncached it was 4 raw repo-view calls/hr for a
# value that's effectively immutable for the life of the checkout.
if command -v _cache_repo_nwo >/dev/null 2>&1; then
    repo="$(_cache_repo_nwo)"
else
    repo="$(chump_gh repo view --json nameWithOwner --jq '.nameWithOwner' 2>/dev/null)"
fi
[ -z "$repo" ] && { echo "[merge-sla-scorecard] no repo nwo; skip" >&2; exit 1; }

prs_tmp="$(mktemp)"
trap 'rm -f "$prs_tmp"' EXIT
chump_gh api "repos/$repo/pulls?state=open&per_page=100" \
    --jq '.[] | "\(.number)|\(.created_at)|\(.title)|\(.head.ref)"' \
    > "$prs_tmp" 2>/dev/null

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
ages_tmp="$(mktemp)"
trap 'rm -f "$prs_tmp" "$ages_tmp"' EXIT

while IFS='|' read -r pr_num created_at title head_ref; do
    [ -z "$pr_num" ] && continue
    open_count=$((open_count + 1))

    created_epoch="$(python3 -c "
from datetime import datetime
import sys
v = sys.argv[1].replace('Z','+00:00')
try: print(int(datetime.fromisoformat(v).timestamp()))
except Exception: print(0)
" "$created_at" 2>/dev/null || echo 0)"
    [ "$created_epoch" = "0" ] && continue
    age_s=$(( now_epoch - created_epoch ))
    echo "$age_s" >> "$ages_tmp"
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

# p50/p90 of open-PR age so the tail is visible alongside the breach count —
# the ratchet (see header) tightens THRESHOLD_MINUTES as p90 falls.
p50=0
p90=0
if [ -s "$ages_tmp" ]; then
    read -r p50 p90 <<EOF
$(python3 -c "
import sys
ages = sorted(int(l) for l in open(sys.argv[1]) if l.strip())
def pct(p):
    if not ages: return 0
    idx = min(len(ages) - 1, int(round((p / 100.0) * (len(ages) - 1))))
    return ages[idx]
print(pct(50), pct(90))
" "$ages_tmp")
EOF
fi

echo "[merge-sla-scorecard] open=$open_count breaches=$breach_count owned=$owned_count escalated=$escalated_count skipped-dedup=$skipped_dedup threshold_s=$THRESHOLD_S p50_s=$p50 p90_s=$p90"
exit 0
