#!/usr/bin/env bash
# scripts/ops/auto-arm-sweeper.sh — INFRA-374
#
# Arm auto-merge on any OPEN PR that lost (or never got) its auto-merge
# state. Caught all night 2026-05-02/03: bot-merge.sh's INFRA-154
# auto-close step occasionally fails between gh pr create and the arm
# step, leaving PRs OPEN-but-unarmed. They sit until manually noticed
# and someone runs `gh pr merge <N> --auto --squash`.
#
# This sweeper finds them and arms them automatically. Safety guards:
#   - Only arms PRs authored by the current user (gh auth user)
#   - Only arms NON-DRAFT PRs
#   - Only arms PRs whose title doesn't contain WIP/wip/[skip]/[hold]
#   - Skips PRs that are MERGEABLE=CONFLICTING (DIRTY) — those need rebase
#     first, not arming
#   - INFRA-8047: skips PRs labelled `hold` or `do-not-merge` (the one
#     documented way to hold a PR — see docs/process/OPERATOR_RUNBOOK.md)
#   - INFRA-8047: respects a human disarm. The sweeper remembers each PR it
#     saw armed (PR number + head SHA). If that PR later shows up unarmed on
#     the same head SHA, someone disabled auto-merge: record who, and do not
#     re-arm until the head SHA changes (a new push = a new green event) and
#     no hold label is present.
#   - Logs every arm action so it's auditable
#
# Recommended cron: every 10 min via launchd. Idempotent — already-armed
# PRs are skipped.
#
# Usage:
#   bash scripts/ops/auto-arm-sweeper.sh             # apply
#   bash scripts/ops/auto-arm-sweeper.sh --dry-run   # report only
#
# Bypass: CHUMP_AUTOARM_SKIP=1 (cron-side global off-switch).

set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"

DRY=0
[[ "${1:-}" == "--dry-run" ]] && DRY=1
[[ "${CHUMP_AUTOARM_SKIP:-0}" == "1" ]] && { echo "[auto-arm] CHUMP_AUTOARM_SKIP=1 — exit"; exit 0; }

command -v gh >/dev/null 2>&1 || { echo "ERROR: gh CLI required" >&2; exit 2; }

# Whoami — only arm our own PRs (so this script is safe to deploy on
# shared infra without trampling sibling-author intent).
ME="$(gh api user --jq '.login' 2>/dev/null || echo '')"
[[ -n "$ME" ]] || { echo "ERROR: gh api user returned empty (not logged in?)" >&2; exit 2; }

STATE_FILE="${CHUMP_AUTOARM_STATE:-$REPO_ROOT/.chump-locks/auto-arm-state.tsv}"
ARMER="${CHUMP_AUTOARM_ARMER:-${REPO_ROOT}/scripts/coord/auto-merge-armer.sh}"
HOLD_LABELS_RE='^(hold|do-not-merge)$'

ts() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }
log() { printf '[auto-arm %s] %s\n' "$(ts)" "$*"; }

# WIP/hold pattern that means "don't arm me yet"
WIP_RE='[Ww][Ii][Pp]|\[skip\]|\[hold\]|\[draft\]|^Draft:|^WIP:'

# State file: num<TAB>sha<TAB>armed|disarmed<TAB>who<TAB>ts  (one line per PR)
state_get() { # <num> -> "sha<TAB>status<TAB>who" or empty
    [[ -f "$STATE_FILE" ]] || return 0
    awk -F'\t' -v n="$1" '$1==n {print $2 "\t" $3 "\t" $4}' "$STATE_FILE" | tail -1
}
state_set() { # <num> <sha> <status> [who]
    [[ "$DRY" -eq 1 ]] && return 0
    mkdir -p "$(dirname "$STATE_FILE")" 2>/dev/null || true
    local tmp="$STATE_FILE.tmp.$$"
    { [[ -f "$STATE_FILE" ]] && awk -F'\t' -v n="$1" '$1!=n' "$STATE_FILE"
      printf '%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "${4:-}" "$(ts)"; } > "$tmp" 2>/dev/null \
        && mv "$tmp" "$STATE_FILE" 2>/dev/null || rm -f "$tmp"
}
disarmer_of() { # <num> -> login of the last auto_merge_disabled actor (best effort)
    gh api "repos/{owner}/{repo}/issues/$1/timeline" --paginate \
        --jq '[.[] | select(.event=="auto_merge_disabled")] | last | .actor.login // empty' \
        2>/dev/null | tail -1
}

log "scanning open PRs authored by $ME"
[[ "$DRY" -eq 1 ]] && log "DRY-RUN — no arms"

# Pull author=me, state=open, not draft. mergeable + autoMergeRequest tell
# us whether to act.
PR_JSON="$(gh pr list \
    --author "$ME" --state open --limit 50 \
    --json number,title,isDraft,mergeStateStatus,autoMergeRequest,labels,headRefOid \
    2>/dev/null || echo '[]')"

armed=0; skipped_wip=0; skipped_dirty=0; skipped_armed=0; skipped_draft=0; skipped_hold=0; skipped_disarmed=0; errors=0

while IFS=$'\t' read -r num title is_draft merge_st has_auto labels sha; do
    [[ -z "$num" ]] && continue
    if [[ "$is_draft" == "true" ]]; then
        skipped_draft=$((skipped_draft + 1))
        continue
    fi
    if [[ "$has_auto" == "true" ]]; then
        skipped_armed=$((skipped_armed + 1))
        state_set "$num" "$sha" armed
        continue
    fi
    # INFRA-8047: operator hold label — never arm.
    held=0
    for l in $labels; do
        [[ "$l" =~ $HOLD_LABELS_RE ]] && held=1
    done
    if [[ "$held" -eq 1 ]]; then
        skipped_hold=$((skipped_hold + 1))
        log "  PR#$num held (hold label) — not arming"
        continue
    fi
    # INFRA-8047: respect a human disarm until the head moves.
    prev="$(state_get "$num")"
    if [[ -n "$prev" ]]; then
        IFS=$'\t' read -r p_sha p_status p_who <<<"$prev"
        if [[ "$p_sha" == "$sha" ]]; then
            if [[ "$p_status" == "armed" ]]; then
                who="$(disarmer_of "$num")"
                state_set "$num" "$sha" disarmed "${who:-unknown}"
                log "  PR#$num was disarmed by ${who:-unknown} — respecting it until a new push"
                skipped_disarmed=$((skipped_disarmed + 1))
                continue
            elif [[ "$p_status" == "disarmed" ]]; then
                skipped_disarmed=$((skipped_disarmed + 1))
                continue
            fi
        fi
    fi
    if [[ "$title" =~ $WIP_RE ]]; then
        skipped_wip=$((skipped_wip + 1))
        continue
    fi
    if [[ "$merge_st" == "DIRTY" || "$merge_st" == "CONFLICTING" ]]; then
        # DIRTY needs rebase, not arm. pr-watch.sh handles that class.
        skipped_dirty=$((skipped_dirty + 1))
        continue
    fi

    # Eligible: open, not draft, not WIP, no autoMerge yet, not DIRTY.
    if [[ "$DRY" -eq 1 ]]; then
        log "  PR#$num would arm — '$title' (merge=$merge_st)"
        armed=$((armed + 1))
        continue
    fi

    # INFRA-1223: route through centralized armer so we inherit 5s spacing +
    # 60/120/240s secondary-rate-limit backoff. Sweeping in a loop without
    # the armer is the dominant agent-blowout failure mode.
    if "$ARMER" --pr "$num" >/dev/null 2>&1; then
        state_set "$num" "$sha" armed
        log "  PR#$num ARMED — '$title'"
        armed=$((armed + 1))
    else
        # Common cause: branch protection requires reviews.
        log "  PR#$num arm failed — likely needs human review or other gate" >&2
        errors=$((errors + 1))
    fi
done < <(printf '%s' "$PR_JSON" | python3 -c "
import sys, json
for pr in json.load(sys.stdin):
    print('\t'.join([
        str(pr.get('number','')),
        (pr.get('title','') or '').replace('\t',' '),
        'true' if pr.get('isDraft') else 'false',
        pr.get('mergeStateStatus','') or '',
        'true' if pr.get('autoMergeRequest') else 'false',
        ' '.join(l.get('name','').replace(' ','_') for l in (pr.get('labels') or [])) or '-',
        pr.get('headRefOid','') or '-',
    ]))
")

echo
log "summary: armed=$armed skipped(armed=$skipped_armed wip=$skipped_wip draft=$skipped_draft dirty=$skipped_dirty hold=$skipped_hold disarmed=$skipped_disarmed) errors=$errors"
[[ "$DRY" -eq 1 ]] && log "(dry-run — no arms applied)"
exit 0
