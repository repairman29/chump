#!/usr/bin/env bash
# shellcheck disable=SC1091,SC2012  # SC1091: lib/ dynamic sources; SC2012: ls used intentionally for glob+head pattern
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

# INFRA-1082: cache-first per-PR meta lookup (zero API calls when cache warm).
# shellcheck source=lib/github_cache.sh
[[ -f "${SCRIPT_DIR}/lib/github_cache.sh" ]] && source "${SCRIPT_DIR}/lib/github_cache.sh"
# INFRA-1241: route ambient appends through helper (surfaces errors to stderr).
# shellcheck source=lib/ambient-write.sh
source "${SCRIPT_DIR}/lib/ambient-write.sh"

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

# INFRA-2728: run-level cost/timing, tracked across the whole scan and
# surfaced in the summary event below (AC2: cost tracked + reported).
run_start_epoch="$(date +%s)"
api_calls=0

command -v gh >/dev/null 2>&1 || { echo "[pr-stuck-announcer] gh missing; skip"; exit 0; }
repo="$(gh repo view --json nameWithOwner --jq '.nameWithOwner' 2>/dev/null)"
api_calls=$((api_calls + 1))
if [ -z "$repo" ]; then
    echo "[pr-stuck-announcer] no repo nwo; skip" >&2
    _ambient_write "$LOCK_DIR/ambient.jsonl" \
        "$(printf '{"ts":"%s","kind":"pr_stuck_announcer_error","stage":"repo_lookup","reason":"no nameWithOwner from gh repo view"}' \
            "$(date -u +%Y-%m-%dT%H:%M:%SZ)")"
    exit 1
fi

# Pull every open PR's relevant state in one REST call.
prs_tmp="$(mktemp)"
trap 'rm -f "$prs_tmp"' EXIT
gh api "repos/$repo/pulls?state=open&per_page=100" \
    --jq '.[] | "\(.number)|\(.updated_at)|\(.head.sha)|\(.title)|\(.head.ref)"' \
    > "$prs_tmp" 2>/dev/null
api_calls=$((api_calls + 1))

if [ ! -s "$prs_tmp" ]; then
    echo "[pr-stuck-announcer] empty PR list"
    _ambient_write "$LOCK_DIR/ambient.jsonl" \
        "$(printf '{"ts":"%s","kind":"pr_stuck_announcer_summary","eligible":0,"announced":0,"skipped_dedup":0,"api_calls":%d,"duration_s":%d}' \
            "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$api_calls" "$(( $(date +%s) - run_start_epoch ))")"
    exit 0
fi

now_epoch="$(date +%s)"
stale_count=0
announced_count=0
skipped_dedup=0

# AC3: failure-class taxonomy — distinguish transient (retry-worthy: CI
# flake, in-flight rebase) from permanent (needs human/agent intervention:
# real merge conflict, real failing check) so consumers can auto-retry
# transient cases without paging on every stuck PR.
classify_failure() {
    local mergeable_state="$1" failing_check="$2"
    case "$mergeable_state" in
        dirty) echo "permanent" ;;  # merge conflict — needs rebase, never self-resolves
        blocked)
            if [ -z "$failing_check" ]; then
                echo "unknown"      # blocked with no identifiable failing check
            else
                case "$failing_check" in
                    *flake*|*flaky*|*timeout*) echo "transient" ;;
                    *) echo "permanent" ;;
                esac
            fi
            ;;
        *) echo "unknown" ;;
    esac
}

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

    # Mergeability — INFRA-1082: cache-first lookup; REST only on cache miss.
    # cache_lookup_pr returns raw_payload_json which contains mergeable_state.
    detail=""
    if declare -F cache_lookup_pr >/dev/null 2>&1; then
        _pr_meta="$(cache_lookup_pr "$pr_num" 2>/dev/null)"
        if [[ -n "$_pr_meta" ]]; then
            detail="$(printf '%s' "$_pr_meta" | python3 -c \
                "import sys,json; print(json.load(sys.stdin).get('mergeable_state','') or '')" \
                2>/dev/null | tr -d '"')"
        fi
    fi
    # Fallback to direct REST if cache miss / lib not loaded.
    if [[ -z "$detail" ]]; then
        detail="$(gh api "repos/$repo/pulls/$pr_num" --jq '.mergeable_state' 2>/dev/null | tr -d '"')"
        api_calls=$((api_calls + 1))
    fi
    case "$detail" in
        dirty|blocked) : ;;  # candidate
        *) continue ;;
    esac

    # Pull last failing check name (best-effort).
    failing_check="$(gh api "repos/$repo/commits/$head_sha/check-runs?per_page=50" \
        --jq '.check_runs[] | select(.conclusion=="failure") | .name' 2>/dev/null \
        | head -1)"
    api_calls=$((api_calls + 1))
    failure_class="$(classify_failure "$detail" "$failing_check")"

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
        # failure_class (AC3) lets consumers auto-retry transient stalls without
        # paging on every stuck PR; permanent/unknown still page as before.
        _ambient_write "$LOCK_DIR/ambient.jsonl" \
            "$(printf '{"ts":"%s","kind":"pr_stuck_announced","pr":%s,"gap":"%s","target":"%s","age_h":%d,"failing_check":"%s","failure_class":"%s"}' \
                "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$pr_num" "$gap_id" "${target:-fleet}" "$((age_s/3600))" "${failing_check:-}" "$failure_class")"
        announced_count=$((announced_count + 1))
        echo "[pr-stuck-announcer] STUCK #$pr_num ($gap_id) → ${target:-fleet} [$failure_class]"
    else
        echo "[pr-stuck-announcer] WOULD STUCK #$pr_num ($gap_id) → ${target:-fleet} [$failure_class] — $reason"
    fi
done < "$prs_tmp"

echo "[pr-stuck-announcer] eligible=$stale_count announced=$announced_count skipped-dedup=$skipped_dedup api_calls=$api_calls"

# AC1/AC2: one summary event per run regardless of outcome (success or
# no-op) so cost (api_calls, duration_s) and reach (eligible/announced) are
# always reported, not only on the announce path.
_ambient_write "$LOCK_DIR/ambient.jsonl" \
    "$(printf '{"ts":"%s","kind":"pr_stuck_announcer_summary","eligible":%d,"announced":%d,"skipped_dedup":%d,"api_calls":%d,"duration_s":%d}' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$stale_count" "$announced_count" "$skipped_dedup" "$api_calls" "$(( $(date +%s) - run_start_epoch ))")"

exit 0
