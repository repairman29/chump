#!/usr/bin/env bash
# stuck-pr-filer.sh — INFRA-307: convert stuck-PR detection into a queued gap
# instead of pinging the human to relay messages between agents.
#
# Why this exists. The original framing was "agent A needs to message agent B
# that B's PR is stuck." That's the wrong abstraction: by the time anyone
# notices, agent B has often exited (one-shot dispatch). The cleanup work
# belongs to whichever fleet agent picks it up next, not to the agent that
# happened to open the PR. So instead of building inboxes, we make stuck PRs
# show up as ordinary INFRA gaps that `run-fleet.sh` claims under the existing
# auto-pickup filters (P1, effort xs/s, INFRA domain).
#
# What it does. Walks open PRs, scores each against four stuck conditions:
#   - DIRTY    : mergeStateStatus=DIRTY for > DIRTY_THRESHOLD_HOURS
#   - CI_RED   : any required check failing for > CI_FAIL_THRESHOLD_HOURS
#   - BEHIND   : > BEHIND_COMMITS_THRESHOLD commits behind base
#   - ORPHAN   : auto-merge disarmed AND no live lease for the PR's gap
# When a PR matches any condition, files an INFRA gap titled
# "PR #<N> stuck — <reason>" with the PR URL, the original gap IDs, and a
# suggested action. Filers de-dup by checking open INFRA gap titles for
# "PR #<N> stuck" first, so re-running the script is idempotent.
#
# Skips. Filing PRs (`chore(gaps): file/reserve …`), drafts, dependabot
# (those go through stale-pr-reaper.sh's natural close path), and PRs that
# already have a stuck-pr filing gap open.
#
# Usage:
#   scripts/ops/stuck-pr-filer.sh                # live run
#   scripts/ops/stuck-pr-filer.sh --dry-run      # print what would be filed
#
# Environment:
#   REMOTE                       git remote (default: origin)
#   BASE                         base branch (default: main)
#   DIRTY_THRESHOLD_HOURS        DIRTY age before filing (default: 4)
#   CI_FAIL_THRESHOLD_HOURS      CI red age before filing (default: 2)
#   BEHIND_COMMITS_THRESHOLD     commits-behind that triggers a gap (default: 20)
#   CHUMP_STUCK_PR_FILER=0       bypass — exit 0 immediately
#
# Designed to be idempotent and watchdog-graded — sources reaper-instrumentation
# so /tmp/chump-reaper-stuck-pr.heartbeat lands on every run and an ambient
# `kind=reaper_run` event is emitted.

set -euo pipefail

if [[ "${CHUMP_STUCK_PR_FILER:-1}" == "0" ]]; then
    echo "[stuck-pr-filer] CHUMP_STUCK_PR_FILER=0 — bypass"
    exit 0
fi

# shellcheck source=../lib/reaper-instrumentation.sh
source "$(dirname "$0")/../lib/reaper-instrumentation.sh"
reaper_setup stuck-pr
reaper_rotate_log /tmp/chump-stuck-pr-filer.out.log
reaper_rotate_log /tmp/chump-stuck-pr-filer.err.log
trap 'rc=$?; [[ $rc -ne 0 ]] && reaper_finish fail "{\"exit\":$rc}"' EXIT

DRY_RUN=0
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=1

REMOTE="${REMOTE:-origin}"
BASE="${BASE:-main}"
DIRTY_THRESHOLD_HOURS="${DIRTY_THRESHOLD_HOURS:-4}"
CI_FAIL_THRESHOLD_HOURS="${CI_FAIL_THRESHOLD_HOURS:-2}"
BEHIND_COMMITS_THRESHOLD="${BEHIND_COMMITS_THRESHOLD:-20}"

green() { printf '\033[0;32m%s\033[0m\n' "$*"; }
red()   { printf '\033[0;31m%s\033[0m\n' "$*"; }
info()  { printf '  %s\n' "$*"; }
warn()  { printf '\033[0;33m  WARN: %s\033[0m\n' "$*"; }
dry()   { printf '  [dry-run] %s\n' "$*"; }

green "=== stuck-pr-filer (base: $REMOTE/$BASE) ==="
[[ $DRY_RUN -eq 1 ]] && info "Dry-run mode — no gaps will be filed."

git fetch "$REMOTE" "$BASE" --quiet 2>/dev/null || {
    red "Could not fetch $REMOTE/$BASE — aborting."; exit 1
}

# Existing stuck-pr filings keyed by PR number. Title convention:
# "PR #<N> stuck — <reason>". We match on " #<N> " to avoid false hits on,
# say, INFRA-#N-shaped substrings.
EXISTING_FILINGS=""
if command -v chump >/dev/null 2>&1; then
    EXISTING_FILINGS=$(chump gap list --status open --json 2>/dev/null \
        | python3 -c "
import json, sys, re
try:
    rows = json.load(sys.stdin)
except Exception:
    sys.exit(0)
for r in rows:
    title = r.get('title') or ''
    m = re.search(r'PR #(\d+) stuck', title)
    if m:
        print(m.group(1))
" 2>/dev/null || true)
fi

already_filed() {
    local pr="$1"
    [[ -n "$EXISTING_FILINGS" ]] || return 1
    grep -qx "$pr" <<<"$EXISTING_FILINGS"
}

# is_filing_pr_title TITLE — PRs whose only intent is to land a new gap YAML.
# Mirrors stale-pr-reaper.sh's exemption (INFRA-219).
is_filing_pr_title() {
    local title="$1"
    case "$title" in
        "chore(gaps): file "*|"chore(gaps): reserve "*) return 0 ;;
        *) return 1 ;;
    esac
}

# pr_age_hours ISO_TIMESTAMP — fractional hours between now and timestamp.
pr_age_hours() {
    local ts="$1"
    [[ -z "$ts" ]] && { echo 0; return; }
    python3 -c "
import sys
from datetime import datetime, timezone
try:
    t = datetime.fromisoformat(sys.argv[1].replace('Z', '+00:00'))
    delta = datetime.now(timezone.utc) - t
    print(int(delta.total_seconds() / 3600))
except Exception:
    print(0)
" "$ts" 2>/dev/null || echo 0
}

# extract_gap_ids TITLE_BODY — pulls DOMAIN-NUM tokens for cross-reference.
extract_gap_ids() {
    grep -oE '\b[A-Z]+-[0-9]+\b' <<<"$1" | sort -u | head -10
}

# has_live_lease GAP_ID — true if any session lease still owns this gap.
has_live_lease() {
    local gid="$1"
    local lock_dir="${REAPER_LOCK_DIR:-.chump-locks}"
    grep -lE "\"gap_id\"[[:space:]]*:[[:space:]]*\"${gid}\"" \
        "$lock_dir"/*.json 2>/dev/null | head -1 >/dev/null
}

# file_stuck_gap PR_NUM REASON SUMMARY DETAILS [STUCK_CLASS]
# INFRA-376: STUCK_CLASS is one of REBASE, CI-RED, BEHIND, ORPHAN.
# Tag goes into the gap title in [brackets] (so the fleet picker can
# route by class) and the description carries a routing hint.
file_stuck_gap() {
    local pr_num="$1"
    local reason="$2"
    local summary="$3"
    local details="$4"
    local stuck_class="${5:-UNKNOWN}"

    local title="PR #${pr_num} stuck [${stuck_class}] — ${reason}"
    local pr_url="https://github.com/repairman29/chump/pull/${pr_num}"

    if [[ $DRY_RUN -eq 1 ]]; then
        dry "would file: $title"
        dry "  $summary"
        return
    fi

    if ! command -v chump >/dev/null 2>&1; then
        warn "chump binary not on PATH — cannot reserve gap; skipping PR #${pr_num}"
        return
    fi

    local reserved
    reserved=$(chump gap reserve --domain INFRA --title "$title" \
        --priority P1 --effort xs 2>&1 | tail -1)
    if [[ ! "$reserved" =~ ^INFRA-[0-9]+$ ]]; then
        warn "chump gap reserve failed for PR #${pr_num}: $reserved"
        return
    fi
    info "  filed $reserved: $title"

    # Description: PR URL + reason + suggested action. Kept short — the next
    # agent reads the PR for details.
    local desc
    desc="${pr_url}

Detected by stuck-pr-filer ($(date -u +%Y-%m-%dT%H:%M:%SZ)).

Trigger: ${reason}
${summary}

Suggested action:
  1. Check the PR — confirm whether the underlying gap landed elsewhere.
  2. If yes: gh pr close ${pr_num} --comment 'superseded'.
  3. If no:  rebase the branch and re-arm via scripts/coord/bot-merge.sh.

${details}"

    chump gap set "$reserved" --description "$desc" 2>/dev/null || \
        warn "  could not set description on $reserved (gap reserved but bare)"

    # Emit ambient ALERT so any human watching the stream sees the dispatch.
    local lock_dir="${REAPER_LOCK_DIR:-.chump-locks}"
    local ambient="$lock_dir/ambient.jsonl"
    local ts
    ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf '{"event":"alert","kind":"pr_stuck","ts":"%s","pr":%s,"reason":"%s","filed_gap":"%s"}\n' \
        "$ts" "$pr_num" "$reason" "$reserved" >> "$ambient" 2>/dev/null || true

    FILED=$((FILED + 1))
}

# Walk open PRs.
PRS_JSON=$(gh pr list --json number,title,headRefName,isDraft,author,mergeStateStatus,autoMergeRequest,updatedAt 2>/dev/null || echo "[]")
if [[ "$PRS_JSON" == "[]" || -z "$PRS_JSON" ]]; then
    info "No open PRs found."
    green "=== stuck-pr-filer done (nothing to do) ==="
    trap - EXIT
    reaper_finish ok '{"filed":0,"skipped":0}'
    exit 0
fi

FILED=0
SKIPPED=0

# Stream PR records as TSV via python so we can keep the bash loop simple.
PR_TSV=$(python3 -c "
import json, sys
rows = json.load(sys.stdin)
for r in rows:
    print('\t'.join([
        str(r.get('number','')),
        r.get('headRefName','') or '',
        (r.get('title','') or '').replace('\t',' '),
        '1' if r.get('isDraft') else '0',
        ((r.get('author') or {}).get('login','') or ''),
        r.get('mergeStateStatus','') or '',
        '1' if r.get('autoMergeRequest') else '0',
        r.get('updatedAt','') or '',
    ]))
" <<<"$PRS_JSON")

while IFS=$'\t' read -r PR_NUM PR_BRANCH PR_TITLE IS_DRAFT AUTHOR MSS HAS_AUTOMERGE UPDATED_AT; do
    [[ -z "$PR_NUM" ]] && continue

    info "PR #$PR_NUM  $PR_TITLE"

    if [[ "$IS_DRAFT" == "1" ]]; then
        info "  → draft, skipping"; SKIPPED=$((SKIPPED+1)); continue
    fi
    if [[ "$AUTHOR" == "dependabot" || "$AUTHOR" == "app/dependabot" ]]; then
        info "  → dependabot, skipping"; SKIPPED=$((SKIPPED+1)); continue
    fi
    if is_filing_pr_title "$PR_TITLE"; then
        info "  → gap-filing PR, skipping"; SKIPPED=$((SKIPPED+1)); continue
    fi
    if already_filed "$PR_NUM"; then
        info "  → already has a stuck-pr filing gap, skipping"; SKIPPED=$((SKIPPED+1)); continue
    fi

    # Cross-reference original gap IDs (for the description).
    GAP_IDS=$(extract_gap_ids "$PR_TITLE")

    # Condition: BEHIND.
    BEHIND=0
    if git fetch "$REMOTE" "$PR_BRANCH" --quiet 2>/dev/null; then
        BEHIND=$(git rev-list --count "$REMOTE/$PR_BRANCH..$REMOTE/$BASE" 2>/dev/null || echo 0)
    fi

    # Condition: DIRTY age (proxy: PR updatedAt — the queue refreshes it on
    # state transitions, so updatedAt of a DIRTY PR is a fair lower-bound on
    # how long it's been DIRTY).
    AGE_HOURS=$(pr_age_hours "$UPDATED_AT")

    # Condition: CI red. Pull check status; treat any FAILURE/CANCELLED as red.
    CI_RED=0
    CI_RED_HOURS=0
    if CHECKS_JSON=$(gh pr checks "$PR_NUM" --json state,completedAt 2>/dev/null); then
        CI_RED_HOURS=$(python3 -c "
import json, sys
from datetime import datetime, timezone
try:
    rows = json.loads(sys.argv[1])
except Exception:
    print(0); sys.exit()
worst = 0
for r in rows:
    state = (r.get('state') or '').upper()
    if state in ('FAILURE','CANCELLED','TIMED_OUT','ACTION_REQUIRED','ERROR'):
        ts = r.get('completedAt')
        if not ts:
            continue
        try:
            t = datetime.fromisoformat(ts.replace('Z','+00:00'))
            hrs = int((datetime.now(timezone.utc) - t).total_seconds() / 3600)
            if hrs > worst:
                worst = hrs
        except Exception:
            pass
print(worst)
" "$CHECKS_JSON" 2>/dev/null || echo 0)
        [[ "$CI_RED_HOURS" -gt 0 ]] && CI_RED=1
    fi

    # Condition: ORPHAN. auto-merge disarmed + no live lease for the cited gap.
    ORPHAN=0
    if [[ "$HAS_AUTOMERGE" == "0" && -n "$GAP_IDS" ]]; then
        ORPHAN=1
        for gid in $GAP_IDS; do
            if has_live_lease "$gid"; then
                ORPHAN=0; break
            fi
        done
    fi

    info "  state: mss=$MSS  behind=$BEHIND  ci_red_hrs=$CI_RED_HOURS  age_hrs=$AGE_HOURS  orphan=$ORPHAN  gaps=${GAP_IDS:-none}"

    REASON=""
    SUMMARY=""
    STUCK_CLASS=""   # INFRA-376: tag the cleanup gap with stuck mode
    if [[ "$MSS" == "DIRTY" && "$AGE_HOURS" -ge "$DIRTY_THRESHOLD_HOURS" ]]; then
        REASON="DIRTY for ${AGE_HOURS}h"
        SUMMARY="Branch needs rebase. mergeStateStatus=DIRTY for ${AGE_HOURS}h (threshold ${DIRTY_THRESHOLD_HOURS}h)."
        STUCK_CLASS="REBASE"
    elif [[ "$CI_RED" == "1" && "$CI_RED_HOURS" -ge "$CI_FAIL_THRESHOLD_HOURS" ]]; then
        REASON="CI red for ${CI_RED_HOURS}h"
        SUMMARY="At least one required check has been failing for ${CI_RED_HOURS}h (threshold ${CI_FAIL_THRESHOLD_HOURS}h)."
        STUCK_CLASS="CI-RED"
    elif [[ "$BEHIND" -ge "$BEHIND_COMMITS_THRESHOLD" ]]; then
        REASON="${BEHIND} commits behind ${BASE}"
        SUMMARY="Branch is ${BEHIND} commits behind ${BASE} (threshold ${BEHIND_COMMITS_THRESHOLD}). The CLAUDE.md hard rule says rebase at 15."
        STUCK_CLASS="BEHIND"
    elif [[ "$ORPHAN" == "1" ]]; then
        REASON="auto-merge disarmed, no live owner"
        SUMMARY="Auto-merge is disarmed and the original gap(s) [${GAP_IDS}] have no live lease — the opening agent likely exited without re-arming."
        STUCK_CLASS="ORPHAN"
    else
        info "  → not stuck"; SKIPPED=$((SKIPPED+1)); continue
    fi

    DETAILS="Original gap(s) cited in PR title/commits: ${GAP_IDS:-none}
Branch: ${PR_BRANCH}
Stuck class: ${STUCK_CLASS} — REBASE→pr-watch-shepherd, CI-RED→ci-flake-rerun or human, BEHIND→pr-watch-shepherd, ORPHAN→auto-arm-sweeper"

    file_stuck_gap "$PR_NUM" "$REASON" "$SUMMARY" "$DETAILS" "$STUCK_CLASS"
done <<<"$PR_TSV"

echo ""
green "=== stuck-pr-filer done: $FILED filed, $SKIPPED skipped ==="

trap - EXIT
reaper_finish ok "{\"filed\":$FILED,\"skipped\":$SKIPPED}"
