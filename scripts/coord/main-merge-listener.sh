#!/usr/bin/env bash
# main-merge-listener.sh — INFRA-2185 (META-125 ring-the-bell, substrate slice)
#
# One-shot tick: diff origin/main against the last-seen SHA bookmark, emit
# one `kind=pr_merged_to_main` event per new commit (oldest first) with
# {pr_url, gap_ids_closed[], files_changed[], commit_sha, ts, lane_tags[]}.
#
# lane_tags[] is computed here (against scripts/coord/curator-lanes.txt) so
# scripts/coord/post-merge-bell.sh can filter on the event payload alone —
# it never has to re-walk the tree.
#
# Bookmark: .chump-locks/main-merge-listener-state.json {"last_sha": "..."}
# First run (no bookmark) seeds the bookmark at current origin/main HEAD
# and emits nothing — avoids a backfill storm of every historical commit.
#
# Usage: scripts/coord/main-merge-listener.sh [--dry-run]
#
# Cadence: session-bound (CronCreate/loop) today; a launchd plist can
# promote it to fleet-durable once ring-the-bell proves out (see
# docs/process/SCHEDULING_LAYERS.md).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=lib/ambient-write.sh
source "$SCRIPT_DIR/lib/ambient-write.sh"

AMBIENT_LOG="${CHUMP_AMBIENT_LOG:-$REPO_ROOT/.chump-locks/ambient.jsonl}"
STATE_FILE="${CHUMP_MERGE_LISTENER_STATE:-$REPO_ROOT/.chump-locks/main-merge-listener-state.json}"
LANES_FILE="${CHUMP_CURATOR_LANES_FILE:-$REPO_ROOT/scripts/coord/curator-lanes.txt}"
DRY_RUN=0
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=1

mkdir -p "$(dirname "$STATE_FILE")"

git -C "$REPO_ROOT" fetch origin main --quiet 2>/dev/null || true
HEAD_SHA="$(git -C "$REPO_ROOT" rev-parse origin/main 2>/dev/null || git -C "$REPO_ROOT" rev-parse main)"

if [[ ! -f "$STATE_FILE" ]]; then
    printf '{"last_sha":"%s"}\n' "$HEAD_SHA" > "$STATE_FILE"
    echo "main-merge-listener: seeded bookmark at $HEAD_SHA (no backfill)"
    exit 0
fi

LAST_SHA="$(grep -o '"last_sha":"[a-f0-9]*"' "$STATE_FILE" | head -1 | cut -d'"' -f4)"
if [[ -z "$LAST_SHA" ]]; then
    printf '{"last_sha":"%s"}\n' "$HEAD_SHA" > "$STATE_FILE"
    echo "main-merge-listener: bookmark unreadable, reseeded at $HEAD_SHA"
    exit 0
fi

if [[ "$LAST_SHA" == "$HEAD_SHA" ]]; then
    exit 0
fi

# Lane globs: role -> comma-separated glob list.
lane_tags_for_files() {
    local files="$1"
    local tags=""
    while IFS=: read -r role globs; do
        [[ -z "$role" || "$role" == \#* ]] && continue
        role="$(echo "$role" | xargs)"
        IFS=',' read -ra glob_arr <<< "$globs"
        local matched=0
        for g in "${glob_arr[@]}"; do
            g="$(echo "$g" | xargs)"
            while IFS= read -r f; do
                [[ -z "$f" ]] && continue
                # shellcheck disable=SC2053
                if [[ "$f" == $g ]]; then
                    matched=1
                    break
                fi
            done <<< "$files"
            [[ "$matched" == 1 ]] && break
        done
        if [[ "$matched" == 1 ]]; then
            tags="${tags:+$tags,}$role"
        fi
    done < "$LANES_FILE"
    echo "$tags"
}

COMMITS="$(git -C "$REPO_ROOT" log --reverse --format='%H' "${LAST_SHA}..${HEAD_SHA}")"
NEW_LAST_SHA="$LAST_SHA"
while IFS= read -r sha; do
    [[ -z "$sha" ]] && continue
    FILES_CHANGED="$(git -C "$REPO_ROOT" diff-tree --no-commit-id --name-only -r "$sha")"
    FILES_CSV="$(echo "$FILES_CHANGED" | paste -sd, -)"
    MSG="$(git -C "$REPO_ROOT" log -1 --format='%s%n%b' "$sha")"
    GAP_IDS="$(echo "$MSG" | grep -oE '[A-Z]+-[0-9]+' | sort -u | paste -sd, - || true)"
    PR_NUM="$(echo "$MSG" | grep -oE '#[0-9]+' | head -1 | tr -d '#' || true)"
    PR_URL=""
    [[ -n "$PR_NUM" ]] && PR_URL="https://github.com/repairman29/chump/pull/${PR_NUM}"
    LANE_TAGS="$(lane_tags_for_files "$FILES_CHANGED")"

    if [[ "$DRY_RUN" == 1 ]]; then
        echo "DRY-RUN: sha=$sha pr=$PR_URL gaps=$GAP_IDS lanes=$LANE_TAGS files=$(echo "$FILES_CHANGED" | wc -l | xargs)"
    else
        JSON="$(printf '{"ts":"%s","kind":"pr_merged_to_main","commit_sha":"%s","pr_url":"%s","gap_ids_closed":"%s","files_changed":"%s","lane_tags":"%s"}' \
            "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$sha" "$PR_URL" "$GAP_IDS" "$FILES_CSV" "$LANE_TAGS")"
        # scanner-anchor: "kind":"pr_merged_to_main"
        _ambient_write "$AMBIENT_LOG" "$JSON"
    fi
    NEW_LAST_SHA="$sha"
done <<< "$COMMITS"

if [[ "$DRY_RUN" != 1 ]]; then
    printf '{"last_sha":"%s"}\n' "$NEW_LAST_SHA" > "$STATE_FILE"
fi
