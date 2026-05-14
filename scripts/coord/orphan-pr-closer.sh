#!/usr/bin/env bash
# orphan-pr-closer.sh — INFRA-1139
#
# Inverse of bounced-pr-detector.sh (INFRA-781).
#
# bounced-pr-detector finds: PR closed unmerged → gap still open (work lost).
# This finds: gap marked done → PR still open (orphan branch eating CI cycles).
#
# Today's evidence (2026-05-14): PR #1736 (INFRA-1024) sat open for ~7 h
# DIRTY against main even though INFRA-1024 was marked done; the
# functionally-equivalent fix had landed via INFRA-1057 (#1778). The rebase
# loop wedged every 5 min trying to re-resolve a semantic conflict for a
# branch that should have been closed at gap-ship time. Cost: ~6 wasted
# queue-driver runs + operator attention to close manually.
#
# Algorithm
#   1. List open PRs (non-draft).
#   2. For each, extract gap ID from PR title (regex: domain-NNNN, e.g.
#      INFRA-1024, CREDIBLE-054).
#   3. `chump gap show <id>` — if status==done, the PR is an orphan.
#   4. Only act on strong signals: PR title contains the gap ID AND
#      `head.updated_at` is older than the freshness threshold (default
#      30 min) so we don't race a merging PR.
#   5. Dry-run: print candidates + would-close action.
#      Apply mode (--apply): post a "superseded by gap close (closed_pr=N)"
#      comment, close the PR, optionally delete the branch.
#
# Idempotent via .chump-locks/orphan-pr-seen.txt.
#
# Bypass / tuning
#   CHUMP_ORPHAN_PR_CLOSER=0          disable entirely
#   CHUMP_ORPHAN_PR_FRESHNESS_MIN=30  skip PRs updated in last N min (default 30)
#   --apply                           actually close PRs (default: dry-run)
#   --delete-branches                 also delete the branch after closing

set -uo pipefail

if [[ "${CHUMP_ORPHAN_PR_CLOSER:-1}" == "0" ]]; then
    echo "[orphan-pr-closer] CHUMP_ORPHAN_PR_CLOSER=0 — skipping" >&2
    exit 0
fi

APPLY=0
DELETE_BRANCHES=0
for arg in "$@"; do
    case "$arg" in
        --apply) APPLY=1 ;;
        --delete-branches) DELETE_BRANCHES=1 ;;
        -h|--help)
            sed -n '2,30p' "$0"
            exit 0 ;;
    esac
done

REPO_ROOT="${CHUMP_REPO:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
FRESHNESS_MIN="${CHUMP_ORPHAN_PR_FRESHNESS_MIN:-30}"
SEEN_FILE="$REPO_ROOT/.chump-locks/orphan-pr-seen.txt"
AMBIENT="$REPO_ROOT/.chump-locks/ambient.jsonl"
mkdir -p "$(dirname "$SEEN_FILE")" 2>/dev/null || true
touch "$SEEN_FILE" 2>/dev/null || true

command -v gh >/dev/null 2>&1 || { echo "[orphan-pr-closer] gh not found, skipping" >&2; exit 0; }

_chump="${HOME}/.cargo/bin/chump"
command -v "$_chump" >/dev/null 2>&1 || _chump="chump"
command -v "$_chump" >/dev/null 2>&1 || { echo "[orphan-pr-closer] chump CLI not found, skipping" >&2; exit 0; }

emit() {
    local kind="$1" pr="$2" gap="$3" note="$4"
    local ts
    ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf '{"ts":"%s","kind":"%s","source":"orphan-pr-closer","pr":%d,"gap":"%s","note":"%s"}\n' \
        "$ts" "$kind" "$pr" "$gap" "$note" >> "$AMBIENT" 2>/dev/null || true
}

# Freshness cutoff (ISO8601).
if cutoff=$(date -v-"${FRESHNESS_MIN}"M -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null); then :
else cutoff=$(date -u -d "-${FRESHNESS_MIN} minutes" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u +%Y-%m-%dT%H:%M:%SZ); fi

# Fetch open non-draft PRs via REST (avoid GraphQL — see INFRA-1080 criticality).
# Output as tab-separated "number<TAB>title<TAB>branch<TAB>updated_at" rows.
PRS_TSV=$(gh api 'repos/{owner}/{repo}/pulls?state=open&per_page=100' \
    --jq '.[] | select(.draft == false) | [.number, .title, .head.ref, .updated_at] | @tsv' \
    2>/dev/null || echo "")

if [[ -z "$PRS_TSV" ]]; then
    exit 0
fi

closed_count=0
candidate_count=0

# Bash 3.2-compatible parse loop (no readarray needed).
while IFS=$'\t' read -r pr title branch updated; do
    [[ -z "$pr" ]] && continue

    # Extract gap ID from title — match DOMAIN-NNN at any position.
    # Domains: INFRA, CREDIBLE, EFFECTIVE, RESILIENT, ZERO-WASTE, MISSION, META, DOC, EVAL, FLEET, MEM
    gap_id=$(echo "$title" | grep -oE '(INFRA|CREDIBLE|EFFECTIVE|RESILIENT|ZERO-WASTE|MISSION|META|DOC|EVAL|FLEET|MEM)-[0-9]+' | head -1)

    if [[ -z "$gap_id" ]]; then
        # Try branch name as fallback (e.g. chump/infra-1024-claim)
        gap_id=$(echo "$branch" | grep -oE 'chump/[a-z-]+-[0-9]+' | sed -E 's|chump/([a-z-]+)-([0-9]+).*|\U\1-\2|' | head -1)
    fi

    [[ -z "$gap_id" ]] && continue

    # Operator escape hatch: "orphan-pr-closer-skip" in title disables for this PR.
    if echo "$title" | grep -qF 'orphan-pr-closer-skip'; then
        continue
    fi

    # Skip if already seen.
    if grep -qxF "closed:$pr" "$SEEN_FILE" 2>/dev/null; then
        continue
    fi

    # Freshness gate — skip if updated within last N min.
    if [[ "$updated" > "$cutoff" ]]; then
        continue
    fi

    # Check gap status.
    gap_yaml=$("$_chump" gap show "$gap_id" 2>/dev/null || true)
    [[ -z "$gap_yaml" ]] && continue

    status=$(echo "$gap_yaml" | grep -E '^  status:' | awk '{print $2}')
    closed_pr=$(echo "$gap_yaml" | grep -E '^  closed_pr:' | awk '{print $2}')

    if [[ "$status" != "done" ]]; then
        continue
    fi

    # If the gap's closed_pr IS this PR, it should already be closed; check
    # GitHub state. If it's a different PR, we have an orphan.
    candidate_count=$((candidate_count + 1))
    if [[ "$closed_pr" == "$pr" ]]; then
        # Gap thinks this PR closed it but PR is still open. Edge case — skip
        # (probably manual gap-mark + auto-merge not yet resolved).
        echo "[orphan-pr-closer] #$pr: gap=$gap_id done with closed_pr=this — skipping (waiting for merge)" >&2
        continue
    fi

    reason="superseded — $gap_id is already status=done"
    if [[ -n "$closed_pr" ]]; then
        reason="$reason (landed via #$closed_pr)"
    fi

    if [[ "$APPLY" == "1" ]]; then
        echo "[orphan-pr-closer] CLOSING #$pr ($gap_id): $reason" >&2
        body="Auto-closing as orphan: gap $gap_id is status=done"
        if [[ -n "$closed_pr" ]]; then
            body="$body (closed via #$closed_pr)"
        fi
        body="$body. This branch's changes are superseded; queued by INFRA-1139 orphan-pr-closer. If this is wrong, reopen and add 'orphan-pr-closer-skip' to the title."
        gh api -X POST "repos/{owner}/{repo}/issues/$pr/comments" -f body="$body" >/dev/null 2>&1 || true
        if gh api -X PATCH "repos/{owner}/{repo}/pulls/$pr" -f state=closed >/dev/null 2>&1; then
            closed_count=$((closed_count + 1))
            echo "closed:$pr" >> "$SEEN_FILE"
            emit "orphan_pr_closed" "$pr" "$gap_id" "$reason"
            # INFRA-1220: stamp cooldown so the gap can't be immediately re-claimed.
            _cooldown_sh="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/gap-cooldown.sh"
            if [[ -x "$_cooldown_sh" ]]; then
                bash "$_cooldown_sh" stamp "$gap_id" --pr "$pr" --reason "orphan_pr_closed" 2>/dev/null || true
            fi
            if [[ "$DELETE_BRANCHES" == "1" && -n "$branch" ]]; then
                gh api -X DELETE "repos/{owner}/{repo}/git/refs/heads/$branch" >/dev/null 2>&1 || true
            fi
        else
            echo "[orphan-pr-closer] FAILED to close #$pr" >&2
            emit "orphan_pr_close_failed" "$pr" "$gap_id" "$reason"
        fi
    else
        echo "[orphan-pr-closer] (dry-run) would close #$pr ($gap_id): $reason" >&2
        emit "orphan_pr_candidate" "$pr" "$gap_id" "$reason"
    fi

done <<< "$PRS_TSV"

if [[ "$APPLY" == "1" ]]; then
    echo "[orphan-pr-closer] closed $closed_count orphan PR(s); $candidate_count candidate(s) total" >&2
else
    echo "[orphan-pr-closer] (dry-run) $candidate_count orphan candidate(s) — re-run with --apply to close" >&2
fi
exit 0
