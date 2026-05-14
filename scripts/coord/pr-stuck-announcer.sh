#!/usr/bin/env bash
# scripts/coord/pr-stuck-announcer.sh — INFRA-1251
#
# Periodic scanner. Finds open PRs that are STUCK (mergeable_state=dirty OR
# blocked-with-failure for ≥ CHUMP_PR_STUCK_AFTER_S) and broadcasts a STUCK
# a2a event. Targeted to the claim-holder if any; fleet broadcast otherwise.
#
# Dedup: each PR has a stamp file under .chump-locks/.stuck-sent/<PR>.ts.
# We refuse to re-broadcast within CHUMP_PR_STUCK_RESEND_COOLDOWN_S
# (default 6h). After a DONE for that gap lands, the stamp is cleared so
# future stalls can fire again.
#
# This is the auto-fire complement to today's manual `broadcast.sh STUCK`
# pattern that operator/agents currently fire by hand.
#
# Usage:
#   scripts/coord/pr-stuck-announcer.sh             # dry-run
#   scripts/coord/pr-stuck-announcer.sh --apply     # actually broadcast
#
# Cron-friendly. Emits kind=pr_stuck_announced events.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd -P)"
LOCK_DIR="$REPO_ROOT/.chump-locks"
STUCK_SENT_DIR="$LOCK_DIR/.stuck-sent"
mkdir -p "$STUCK_SENT_DIR" 2>/dev/null || true

STUCK_AFTER_S="${CHUMP_PR_STUCK_AFTER_S:-7200}"            # 2h
RESEND_COOLDOWN_S="${CHUMP_PR_STUCK_RESEND_COOLDOWN_S:-21600}"  # 6h

APPLY=0
while [ $# -gt 0 ]; do
    case "$1" in
        --apply) APPLY=1; shift ;;
        --after) STUCK_AFTER_S="$2"; shift 2 ;;
        --cooldown) RESEND_COOLDOWN_S="$2"; shift 2 ;;
        -h|--help) sed -n '2,22p' "$0" | sed 's/^# \?//'; exit 0 ;;
        *) echo "[pr-stuck-announcer] unknown arg: $1" >&2; exit 2 ;;
    esac
done

command -v gh >/dev/null 2>&1 || { echo "[pr-stuck-announcer] gh missing; skip"; exit 0; }
repo="$(gh repo view --json nameWithOwner --jq '.nameWithOwner' 2>/dev/null)"
[ -z "$repo" ] && { echo "[pr-stuck-announcer] no repo nwo; skip" >&2; exit 1; }

# Pull every open PR's relevant state in one REST call.
prs_tmp="$(mktemp)"
trap 'rm -f "$prs_tmp"' EXIT
gh api "repos/$repo/pulls?state=open&per_page=100" \
    --jq '.[] | "\(.number)|\(.updated_at)|\(.head.sha)|\(.title)|\(.head.ref)"' \
    > "$prs_tmp" 2>/dev/null

[ ! -s "$prs_tmp" ] && { echo "[pr-stuck-announcer] empty PR list"; exit 0; }

now_epoch="$(date +%s)"
stale_count=0
announced_count=0
skipped_dedup=0

while IFS='|' read -r pr_num updated_at head_sha title head_ref; do
    [ -z "$pr_num" ] && continue

    # Update-time age — proxy for "no recent owner activity".
    upd_epoch="$(python3 -c "
from datetime import datetime
import sys
v = sys.argv[1].replace('Z','+00:00')
try: print(int(datetime.fromisoformat(v).timestamp()))
except Exception: print(0)
" "$updated_at" 2>/dev/null || echo 0)"
    [ "$upd_epoch" = "0" ] && continue
    age_s=$(( now_epoch - upd_epoch ))
    [ "$age_s" -lt "$STUCK_AFTER_S" ] && continue

    # Mergeability — single REST hit per candidate (only those past age threshold).
    # Strip JSON quotes (gh --jq returns "dirty" not dirty without -r).
    detail="$(gh api "repos/$repo/pulls/$pr_num" --jq '.mergeable_state' 2>/dev/null | tr -d '"')"
    case "$detail" in
        dirty|blocked) : ;;  # candidate
        *) continue ;;
    esac

    # Pull last failing check name (best-effort).
    failing_check="$(gh api "repos/$repo/commits/$head_sha/check-runs?per_page=50" \
        --jq '.check_runs[] | select(.conclusion=="failure") | .name' 2>/dev/null \
        | head -1)"

    # Extract gap-id from title (first one).
    gap_id="$(echo "$title" | grep -oE '[A-Z]+-[0-9]+' | head -1)"
    [ -z "$gap_id" ] && continue

    stale_count=$((stale_count + 1))

    # Dedup: skip if a stamp exists within cooldown.
    stamp="$STUCK_SENT_DIR/$pr_num.ts"
    if [ -f "$stamp" ]; then
        stamp_ts="$(cat "$stamp" 2>/dev/null || echo 0)"
        if [ "$stamp_ts" -gt 0 ] && [ $(( now_epoch - stamp_ts )) -lt "$RESEND_COOLDOWN_S" ]; then
            skipped_dedup=$((skipped_dedup + 1))
            continue
        fi
    fi

    reason="PR #$pr_num ($head_ref) is $detail for ~$((age_s/3600))h."
    [ -n "$failing_check" ] && reason="$reason last-failing-check=$failing_check."
    reason="$reason Picker needed: fetch + checkout $head_ref; rebase origin/main; resolve conflicts; push."

    # Target the claim-holder if any; otherwise fleet broadcast.
    claim_lease="$(ls "$LOCK_DIR"/claim-"$(echo "$gap_id" | tr '[:upper:]' '[:lower:]')"-*.json 2>/dev/null | head -1 || true)"
    target=""
    if [ -n "$claim_lease" ]; then
        target="$(python3 -c "
import json, sys
try: print(json.load(open(sys.argv[1])).get('session_id',''))
except Exception: print('')
" "$claim_lease" 2>/dev/null || echo "")"
    fi

    if [ "$APPLY" -eq 1 ]; then
        if [ -n "$target" ]; then
            "$SCRIPT_DIR/broadcast.sh" --to "$target" --corr "$gap_id" STUCK "$gap_id" "$reason" >/dev/null
        else
            "$SCRIPT_DIR/broadcast.sh" --corr "$gap_id" STUCK "$gap_id" "$reason" >/dev/null
        fi
        printf '%s' "$now_epoch" > "$stamp"
        # Audit ambient event distinct from STUCK itself (this is the *scanner's* announce).
        printf '{"ts":"%s","kind":"pr_stuck_announced","pr":%s,"gap":"%s","target":"%s","age_h":%d,"failing_check":"%s"}\n' \
            "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$pr_num" "$gap_id" "${target:-fleet}" "$((age_s/3600))" "${failing_check:-}" \
            >> "$LOCK_DIR/ambient.jsonl" 2>/dev/null || true
        announced_count=$((announced_count + 1))
        echo "[pr-stuck-announcer] STUCK #$pr_num ($gap_id) → ${target:-fleet}"
    else
        echo "[pr-stuck-announcer] WOULD STUCK #$pr_num ($gap_id) → ${target:-fleet} — $reason"
    fi
done < "$prs_tmp"

echo "[pr-stuck-announcer] eligible=$stale_count announced=$announced_count skipped-dedup=$skipped_dedup"
exit 0
