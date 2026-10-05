#!/usr/bin/env bash
# scripts/coord/keep-mergeable-organ.sh — RESILIENT-342
#
# Keep-mergeable organ: continuously rebase EVERY open fleet PR onto green
# main + rerun stale/failed checks so PRs reach green-ready (CLEAN).
#
# Why this exists (2026-08-15 evidence): a per-PR mergeStateStatus scan found
# 6 open PRs, 3 DIRTY, 0 green-ready (CLEAN), while chump-armed-rebaser.timer
# was active but not clearing them and the (now-live) merge train had nothing
# to pull. The binding throughput constraint is the REBASE/keep-mergeable
# stage, not the merge stage — open PRs rot into DIRTY faster than they are
# rebased onto green main, so they never reach green-ready.
#
# What makes this different from the existing rebase bots:
#   - armed-pr-rebaser.sh / pr-auto-rebase.sh / stale-pr-rebase-bot.sh all
#     restrict themselves to PRs with autoMergeRequest ARMED. A PR that is
#     DIRTY but not yet armed rots unnoticed by all three.
#   - none of the three reruns FAILED/stale checks — a PR that is CLEAN on
#     mergeStateStatus but has a stale failed check from an old base sits
#     forever needing a human to click "re-run".
#   - This organ scans EVERY open PR (armed or not) and:
#       1. rebases DIRTY/BEHIND PRs onto current green main (gh-side, with
#          a local-worktree fallback for the INFRA-1958 false-positive class)
#       2. reruns FAILED checks on CLEAN/BLOCKED PRs so a stale red doesn't
#          block a PR that would pass against current main
#       3. escalates (never silently drops) any PR it cannot auto-resolve
#          after CHUMP_KEEP_MERGEABLE_STRIKE_LIMIT attempts
#
# Usage:
#   bash scripts/coord/keep-mergeable-organ.sh [--dry-run]
#
# Telemetry (.chump-locks/ambient.jsonl):
#   kind=keep_mergeable_rebased        — DIRTY/BEHIND PR rebased + pushed clean
#   kind=keep_mergeable_rebase_failed  — rebase attempt failed (strike recorded)
#   kind=keep_mergeable_checks_rerun   — stale/failed check(s) rerun on a PR
#   kind=keep_mergeable_unresolvable   — strike limit reached; operator must act
#   kind=keep_mergeable_tick           — per-cycle summary counts
#
# Env knobs:
#   CHUMP_KEEP_MERGEABLE_STRIKE_LIMIT     — strikes before escalation (default 3)
#   CHUMP_KEEP_MERGEABLE_HYSTERESIS_MINS  — skip re-attempt within N min (default 10)
#   CHUMP_KEEP_MERGEABLE_AMBIENT_FILE     — override ambient.jsonl path (tests)
#   CHUMP_KEEP_MERGEABLE_STRIKES_DIR      — override strikes dir path (tests)
#   CHUMP_KEEP_MERGEABLE_BROADCAST_SCRIPT — override broadcast.sh path (tests)
#   CHUMP_KEEP_MERGEABLE_GH_FIXTURE       — fixture JSON; overrides gh pr list (tests)
#   CHUMP_KEEP_MERGEABLE_NOW_OVERRIDE     — ISO-8601 "now" override (tests)

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel 2>/dev/null || (cd "$SCRIPT_DIR/../.." && pwd))"

_GIT_COMMON="$(git -C "$REPO_ROOT" rev-parse --git-common-dir 2>/dev/null || echo ".git")"
if [[ "$_GIT_COMMON" == ".git" ]]; then
    MAIN_REPO="$REPO_ROOT"
else
    MAIN_REPO="$(cd "$(dirname "$_GIT_COMMON")" && pwd)"
fi
LOCK_DIR="$MAIN_REPO/.chump-locks"
mkdir -p "$LOCK_DIR"

STRIKE_LIMIT="${CHUMP_KEEP_MERGEABLE_STRIKE_LIMIT:-3}"
HYSTERESIS_MINS="${CHUMP_KEEP_MERGEABLE_HYSTERESIS_MINS:-10}"
AMBIENT="${CHUMP_KEEP_MERGEABLE_AMBIENT_FILE:-$LOCK_DIR/ambient.jsonl}"
STRIKES_DIR="${CHUMP_KEEP_MERGEABLE_STRIKES_DIR:-$LOCK_DIR/keep-mergeable-strikes}"
BROADCAST_SCRIPT="${CHUMP_KEEP_MERGEABLE_BROADCAST_SCRIPT:-$REPO_ROOT/scripts/coord/broadcast.sh}"
mkdir -p "$STRIKES_DIR"

DRY_RUN=0
for _a in "$@"; do
    case "$_a" in
    --dry-run) DRY_RUN=1 ;;
    esac
done

_ts() {
    if [[ -n "${CHUMP_KEEP_MERGEABLE_NOW_OVERRIDE:-}" ]]; then
        printf '%s' "$CHUMP_KEEP_MERGEABLE_NOW_OVERRIDE"
    else
        date -u +%Y-%m-%dT%H:%M:%SZ
    fi
}

emit() {
    local kind="$1" pr="${2:-}" extra="${3:-}"
    local ts; ts="$(_ts)"
    local line
    if [[ -n "$pr" && -n "$extra" ]]; then
        line="{\"ts\":\"$ts\",\"kind\":\"$kind\",\"pr\":$pr,$extra}"
    elif [[ -n "$pr" ]]; then
        line="{\"ts\":\"$ts\",\"kind\":\"$kind\",\"pr\":$pr}"
    else
        line="{\"ts\":\"$ts\",\"kind\":\"$kind\"}"
    fi
    printf '%s\n' "$line" >> "$AMBIENT"
}

log() { printf '[keep-mergeable-organ] %s\n' "$*"; }

iso_to_epoch() {
    python3 -c "
from datetime import datetime, timezone
try:
    t = datetime.fromisoformat('$1'.replace('Z','+00:00'))
    print(int(t.timestamp()))
except Exception:
    print(0)
" 2>/dev/null || echo 0
}

now_epoch() {
    if [[ -n "${CHUMP_KEEP_MERGEABLE_NOW_OVERRIDE:-}" ]]; then
        iso_to_epoch "$CHUMP_KEEP_MERGEABLE_NOW_OVERRIDE"
    else
        date -u +%s
    fi
}

mins_since() {
    local epoch; epoch="$(iso_to_epoch "$1")"
    local now; now="$(now_epoch)"
    echo $(( (now - epoch) / 60 ))
}

strike_file() { printf '%s/%s.json' "$STRIKES_DIR" "$1"; }

read_strike_field() {
    local file="$1" field="$2" default="$3"
    [[ -f "$file" ]] || { printf '%s' "$default"; return; }
    python3 -c "
import json
try:
    d = json.load(open('$file'))
    v = d.get('$field', '$default')
    print(v)
except Exception:
    print('$default')
" 2>/dev/null || printf '%s' "$default"
}

record_strike() {
    local file="$1" pr="$2" branch="$3" strikes="$4" ts="$5"
    python3 - "$file" <<PYEOF
import json, sys
path = sys.argv[1]
try:
    d = json.load(open(path))
except Exception:
    d = {}
d['strikes'] = $strikes
d['pr'] = $pr
d['branch'] = '$branch'
d['last_attempt_ts'] = '$ts'
open(path, 'w').write(json.dumps(d, indent=2) + '\n')
PYEOF
}

# ── Fetch every open PR (NOT filtered by auto-merge-armed) ───────────────────
if [[ -n "${CHUMP_KEEP_MERGEABLE_GH_FIXTURE:-}" ]]; then
    PRS_JSON="$(cat "$CHUMP_KEEP_MERGEABLE_GH_FIXTURE")"
else
    PRS_JSON="$(gh pr list \
        --state open \
        --limit 100 \
        --json number,headRefName,mergeStateStatus,statusCheckRollup \
        2>/dev/null || echo '[]')"
fi

if [[ -z "$PRS_JSON" || "$PRS_JSON" == "[]" ]]; then
    log "No open PRs found (or gh unavailable)."
    emit "keep_mergeable_tick" "" "\"open_prs\":0,\"rebased\":0,\"checks_rerun\":0,\"failed\":0,\"escalated\":0"
    exit 0
fi

# rows: number \t headRefName \t mergeStateStatus \t comma-separated-failed-run-ids
ROWS="$(printf '%s' "$PRS_JSON" | python3 -c "
import json, sys, re
rows = json.load(sys.stdin)
for r in rows:
    num = r.get('number', '')
    branch = r.get('headRefName', '') or ''
    mss = r.get('mergeStateStatus', '') or ''
    run_ids = []
    for c in (r.get('statusCheckRollup') or []):
        if (c.get('conclusion') or '').upper() == 'FAILURE':
            url = c.get('detailsUrl') or ''
            m = re.search(r'/actions/runs/(\d+)', url)
            if m:
                run_ids.append(m.group(1))
    print('\t'.join([str(num), branch, mss, ','.join(sorted(set(run_ids)))]))
" 2>/dev/null || true)"

[[ -z "$ROWS" ]] && ROWS=""

OPEN_COUNT=0
REBASED=0
CHECKS_RERUN=0
FAILED=0
ESCALATED=0

while IFS=$'\t' read -r PR BRANCH MSS RUN_IDS; do
    [[ -z "$PR" ]] && continue
    OPEN_COUNT=$((OPEN_COUNT + 1))
    log "Checking #$PR (branch=$BRANCH, mss=$MSS, failed_runs=${RUN_IDS:-none})"

    SFILE="$(strike_file "$PR")"
    last_attempt="$(read_strike_field "$SFILE" "last_attempt_ts" "")"
    if [[ -n "$last_attempt" ]]; then
        mins_ago="$(mins_since "$last_attempt")"
        if (( mins_ago < HYSTERESIS_MINS )); then
            log "  SKIP #$PR — attempted ${mins_ago}m ago (hysteresis=${HYSTERESIS_MINS}m)"
            continue
        fi
    fi

    strikes="$(read_strike_field "$SFILE" "strikes" "0")"
    if (( strikes >= STRIKE_LIMIT )); then
        log "  SKIP #$PR — already at ${strikes} strikes (limit=${STRIKE_LIMIT}); waiting for operator action"
        continue
    fi

    if (( DRY_RUN )); then
        log "  DRY-RUN: would act on #$PR (mss=$MSS, failed_runs=${RUN_IDS:-none})"
        continue
    fi

    resolved=0
    NOW_TS="$(_ts)"

    # ── DIRTY/BEHIND: rebase onto green main ──────────────────────────────────
    if [[ "$MSS" == "DIRTY" || "$MSS" == "BEHIND" ]]; then
        if gh pr update-branch "$PR" >/dev/null 2>&1; then
            log "  OK #$PR — GH-side rebase succeeded."
            emit "keep_mergeable_rebased" "$PR" "\"branch\":\"$BRANCH\",\"method\":\"gh_update_branch\""
            rm -f "$SFILE"
            REBASED=$((REBASED + 1))
            resolved=1
        else
            WT="$(mktemp -d -t chump-keep-mergeable-XXXXXX)"
            git -C "$REPO_ROOT" fetch origin "$BRANCH" --quiet 2>/dev/null || true
            git -C "$REPO_ROOT" fetch origin main --quiet 2>/dev/null || true
            if git -C "$REPO_ROOT" worktree add "$WT" "origin/$BRANCH" >/dev/null 2>&1; then
                if (cd "$WT" && git rebase origin/main >/dev/null 2>&1); then
                    if (cd "$WT" && git push origin "HEAD:$BRANCH" --force-with-lease >/dev/null 2>&1); then
                        log "  OK #$PR — local-rebase fallback succeeded."
                        emit "keep_mergeable_rebased" "$PR" "\"branch\":\"$BRANCH\",\"method\":\"local_rebase_fallback\""
                        rm -f "$SFILE"
                        REBASED=$((REBASED + 1))
                        resolved=1
                    fi
                else
                    (cd "$WT" && git rebase --abort >/dev/null 2>&1) || true
                fi
                git -C "$REPO_ROOT" worktree remove "$WT" --force >/dev/null 2>&1 || true
            fi
            rm -rf "$WT" 2>/dev/null || true
        fi
    fi

    # ── Stale/failed checks on an otherwise-mergeable PR: rerun ──────────────
    if (( ! resolved )) && [[ -n "$RUN_IDS" ]]; then
        rerun_any=0
        IFS=',' read -ra IDS <<< "$RUN_IDS"
        for rid in "${IDS[@]}"; do
            [[ -z "$rid" ]] && continue
            if gh run rerun "$rid" --failed >/dev/null 2>&1; then
                rerun_any=1
            fi
        done
        if (( rerun_any )); then
            log "  OK #$PR — reran stale/failed checks (${RUN_IDS})."
            emit "keep_mergeable_checks_rerun" "$PR" "\"branch\":\"$BRANCH\",\"run_ids\":\"$RUN_IDS\""
            rm -f "$SFILE"
            CHECKS_RERUN=$((CHECKS_RERUN + 1))
            resolved=1
        fi
    fi

    (( resolved )) && continue

    # Nothing to do for this PR this cycle (e.g. CLEAN with no failed checks).
    if [[ "$MSS" != "DIRTY" && "$MSS" != "BEHIND" && -z "$RUN_IDS" ]]; then
        continue
    fi

    # ── Neither rebase nor rerun resolved it: strike ──────────────────────────
    new_strikes=$(( strikes + 1 ))
    record_strike "$SFILE" "$PR" "$BRANCH" "$new_strikes" "$NOW_TS"
    log "  Strike ${new_strikes}/${STRIKE_LIMIT} recorded for #$PR."
    emit "keep_mergeable_rebase_failed" "$PR" "\"branch\":\"$BRANCH\",\"mss\":\"$MSS\",\"strikes\":$new_strikes,\"strike_limit\":$STRIKE_LIMIT"
    FAILED=$((FAILED + 1))

    if (( new_strikes >= STRIKE_LIMIT )); then
        log "  WARN #$PR — ${new_strikes} strikes reached. Operator must decide. PR left open."
        emit "keep_mergeable_unresolvable" "$PR" "\"branch\":\"$BRANCH\",\"strikes\":$new_strikes,\"note\":\"operator_action_required\""
        if [[ -x "$BROADCAST_SCRIPT" ]]; then
            "$BROADCAST_SCRIPT" --urgency WARN WARN \
                "PR #${PR} (branch=${BRANCH}) is not reaching green-ready after ${new_strikes} keep-mergeable strikes. Operator must resolve or close manually. See .chump-locks/keep-mergeable-strikes/${PR}.json" \
                2>/dev/null || true
        fi
        ESCALATED=$((ESCALATED + 1))
    fi
done <<< "$ROWS"

log "done — open=${OPEN_COUNT} rebased=${REBASED} checks_rerun=${CHECKS_RERUN} failed=${FAILED} escalated=${ESCALATED}"
emit "keep_mergeable_tick" "" "\"open_prs\":$OPEN_COUNT,\"rebased\":$REBASED,\"checks_rerun\":$CHECKS_RERUN,\"failed\":$FAILED,\"escalated\":$ESCALATED"
exit 0
