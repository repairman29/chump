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

ts() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }
log() { printf '[auto-arm %s] %s\n' "$(ts)" "$*"; }

# WIP/hold pattern that means "don't arm me yet"
WIP_RE='[Ww][Ii][Pp]|\[skip\]|\[hold\]|\[draft\]|^Draft:|^WIP:'

log "scanning open PRs authored by $ME"
[[ "$DRY" -eq 1 ]] && log "DRY-RUN — no arms"

# Pull author=me, state=open, not draft. mergeable + autoMergeRequest tell
# us whether to act.
PR_JSON="$(gh pr list \
    --author "$ME" --state open --limit 50 \
    --json number,title,isDraft,mergeStateStatus,autoMergeRequest \
    2>/dev/null || echo '[]')"

armed=0; skipped_wip=0; skipped_dirty=0; skipped_armed=0; skipped_draft=0; errors=0

while IFS=$'\t' read -r num title is_draft merge_st has_auto; do
    [[ -z "$num" ]] && continue
    if [[ "$is_draft" == "true" ]]; then
        skipped_draft=$((skipped_draft + 1))
        continue
    fi
    if [[ "$has_auto" == "true" ]]; then
        skipped_armed=$((skipped_armed + 1))
        continue
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
    if "${REPO_ROOT}/scripts/coord/auto-merge-armer.sh" --pr "$num" >/dev/null 2>&1; then
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
    ]))
")

echo
log "summary: armed=$armed skipped(armed=$skipped_armed wip=$skipped_wip draft=$skipped_draft dirty=$skipped_dirty) errors=$errors"
[[ "$DRY" -eq 1 ]] && log "(dry-run — no arms applied)"
exit 0
