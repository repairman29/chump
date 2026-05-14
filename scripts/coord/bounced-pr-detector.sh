#!/usr/bin/env bash
# bounced-pr-detector.sh — INFRA-781
#
# Watches for PRs that closed without merging and where the carried work
# never re-landed via another PR. Catches the failure mode demonstrated
# by today's #1349 (EVAL-026 default-flip): an agent-authored PR was
# closed when its branch got recycled for unrelated work; the original
# default-flip never made it to main and silently bounced.
#
# Why ghost-gap-reaper doesn't cover this
#   ghost-gap-reaper.sh (INFRA-556) only inspects gaps with status=done
#   whose closed_pr was closed without merging. It rolls the gap back
#   to open. That covers "we marked it done but the merge never
#   happened" — useful but narrow.
#
#   Today's failure was different: a behavior-change PR (#1349) that
#   wasn't tied to a tracked gap, the agent closed it before any gap
#   was marked done, and the work disappeared. ghost-gap-reaper had
#   nothing to inspect.
#
# What this watcher does
#   1. Query `gh pr list --state closed --search "-is:merged
#      closed:>=$LOOKBACK"` for recently-closed-without-merge PRs.
#   2. For each, fetch the diff at close time and the list of changed
#      files.
#   3. Cross-check whether equivalent file content has landed in any
#      MERGED commit since the close timestamp. The check is
#      conservative: if any of the changed files appears in a merged
#      commit since with substantial overlap, treat as "re-landed."
#   4. If NOT re-landed → emit `kind=pr_bounced_unfinished` AND file
#      a recovery gap pointing at the bounced PR with a one-line
#      summary of what was lost.
#   5. If re-landed → emit `kind=pr_bounced_relanded` (informational
#      only; no gap filed).
#
# Run cadence
#   Cron-friendly. Recommended every 30 min alongside ghost-gap-reaper.
#   Idempotent: a state file at .chump-locks/bounced-pr-seen.txt records
#   PR numbers already processed so we don't double-file.
#
# Bypass / tuning
#   CHUMP_BOUNCED_PR_DETECTOR=0 — disable entirely.
#   CHUMP_BOUNCED_PR_LOOKBACK_HOURS=24 — how far back to scan (default 24).
#   CHUMP_BOUNCED_PR_AUTO_FILE_GAP=1 — file recovery gaps automatically
#     (default on). Set to 0 to emit ambient events only and surface to
#     operator instead.

set -uo pipefail

if [[ "${CHUMP_BOUNCED_PR_DETECTOR:-1}" == "0" ]]; then
    echo "[bounced-pr] CHUMP_BOUNCED_PR_DETECTOR=0 — skipping" >&2
    exit 0
fi

REPO_ROOT="${CHUMP_REPO:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
LOOKBACK_HOURS="${CHUMP_BOUNCED_PR_LOOKBACK_HOURS:-24}"
AUTO_FILE_GAP="${CHUMP_BOUNCED_PR_AUTO_FILE_GAP:-1}"
SEEN_FILE="$REPO_ROOT/.chump-locks/bounced-pr-seen.txt"
AMBIENT="$REPO_ROOT/.chump-locks/ambient.jsonl"

mkdir -p "$(dirname "$SEEN_FILE")" "$(dirname "$AMBIENT")" 2>/dev/null || true
touch "$SEEN_FILE" 2>/dev/null || true

command -v gh >/dev/null 2>&1 || { echo "[bounced-pr] gh not found, skipping" >&2; exit 0; }

_chump="${HOME}/.cargo/bin/chump"
command -v "$_chump" >/dev/null 2>&1 || _chump="chump"

emit_ambient() {
    local kind="$1"; shift
    local pr_num="$1"; shift
    local note="$*"
    local ts
    ts="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo unknown)"
    local payload
    payload=$(printf '{"ts":"%s","event":"ALERT","kind":"%s","source":"bounced-pr-detector","pr":%d,"note":"%s"}\n' \
        "$ts" "$kind" "$pr_num" "$note")
    echo "$payload" >> "$AMBIENT" 2>/dev/null || true
    echo "[bounced-pr] $payload" >&2
}

# Compute lookback cutoff in ISO8601. macOS / GNU date both supported.
if date -v-"${LOOKBACK_HOURS}"H -u +%Y-%m-%dT%H:%M:%SZ >/dev/null 2>&1; then
    CUTOFF=$(date -v-"${LOOKBACK_HOURS}"H -u +%Y-%m-%dT%H:%M:%SZ)
else
    CUTOFF=$(date -u -d "-${LOOKBACK_HOURS} hours" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u +%Y-%m-%dT%H:%M:%SZ)
fi

# Fetch closed-not-merged PRs since cutoff.
PRS_JSON=$(gh pr list --state closed --limit 100 --search "-is:merged closed:>=$CUTOFF" \
    --json number,closedAt,headRefName,title,files,mergedAt 2>/dev/null || echo "[]")

if [[ -z "$PRS_JSON" || "$PRS_JSON" == "[]" ]]; then
    exit 0
fi

# Classify each closed-unmerged PR via the helper.
CLASSIFIER="$REPO_ROOT/scripts/coord/_bounced_pr_classifier.py"
if [[ ! -x "$CLASSIFIER" ]]; then
    echo "[bounced-pr] classifier not found at $CLASSIFIER" >&2
    exit 0
fi

ACTIONS=$(echo "$PRS_JSON" | python3 "$CLASSIFIER" "$REPO_ROOT" 2>/dev/null || true)

if [[ -z "$ACTIONS" ]]; then
    exit 0
fi

# Process each action line — emit ambient + optionally file gap.
while IFS='|' read -r status pr_num title ratio files_csv; do
    [[ -z "$pr_num" ]] && continue
    case "$status" in
        RELANDED)
            emit_ambient "pr_bounced_relanded" "$pr_num" \
                "PR closed unmerged but $(printf '%.0f%%' "$(echo "$ratio * 100" | bc -l 2>/dev/null || echo "${ratio}")")  of files re-landed via subsequent commits — informational"
            ;;
        BOUNCED)
            emit_ambient "pr_bounced_unfinished" "$pr_num" \
                "PR closed unmerged with no equivalent content landed since (ratio=$ratio); files=$files_csv"

            if [[ "$AUTO_FILE_GAP" == "1" ]] && command -v "$_chump" >/dev/null 2>&1; then
                # Idempotency: only file once per PR. Use seen-file as the key.
                if ! grep -qxF "filed:$pr_num" "$SEEN_FILE" 2>/dev/null; then
                    title_short=$(echo "$title" | head -c 80)
                    gap_title="RESILIENT: re-pick bounced PR #$pr_num — $title_short — closed without merge per INFRA-781 detector; equivalent content not seen in main since close. Files: $files_csv. Investigate whether work should be re-shipped on a fresh branch."
                    if "$_chump" gap reserve --domain INFRA --title "$gap_title" --priority P2 --effort xs >/dev/null 2>&1; then
                        echo "filed:$pr_num" >> "$SEEN_FILE"
                        echo "[bounced-pr] auto-filed recovery gap for PR #$pr_num" >&2
                    fi
                fi
            fi
            ;;
    esac
done <<< "$ACTIONS"

exit 0
