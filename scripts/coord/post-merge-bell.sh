#!/usr/bin/env bash
# post-merge-bell.sh — INFRA-2185 (META-125 ring-the-bell, fan-out slice)
#
# Tails .chump-locks/ambient.jsonl for `kind=pr_merged_to_main` events not
# yet processed (bookmarked by byte offset), and for each one, fans out to
# every curator role whose lane_tags[] the event already carries a match
# for (computed upstream by main-merge-listener.sh — this script does not
# re-walk the tree). For each match:
#   1. emit kind=curator_lane_match (debug surface)
#   2. `chump curator refresh <role> --pr-url .. --commit-sha .. --gap-ids ..`
#      — updates .chump-locks/curator-memory/<role>.json and emits
#      kind=curator_refreshed (+ kind=curator_staleness_finding if the Rust
#      side detects one).
#
# Usage: scripts/coord/post-merge-bell.sh [--dry-run]
#
# Substrate note: this is the poll-based fallback for the NATS-subscriber
# daemon described in META-125 C4 (not yet landed). Once that daemon ships,
# this script's fan-out logic moves to a live subscriber; the per-curator
# refresh action (`chump curator refresh`) is unchanged either way.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=lib/ambient-write.sh
source "$SCRIPT_DIR/lib/ambient-write.sh"

AMBIENT_LOG="${CHUMP_AMBIENT_LOG:-$REPO_ROOT/.chump-locks/ambient.jsonl}"
BOOKMARK_FILE="${CHUMP_POST_MERGE_BELL_STATE:-$REPO_ROOT/.chump-locks/post-merge-bell-state.txt}"
DRY_RUN=0
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=1

[[ -f "$AMBIENT_LOG" ]] || exit 0
mkdir -p "$(dirname "$BOOKMARK_FILE")"

LAST_OFFSET=0
[[ -f "$BOOKMARK_FILE" ]] && LAST_OFFSET="$(cat "$BOOKMARK_FILE" 2>/dev/null || echo 0)"
[[ "$LAST_OFFSET" =~ ^[0-9]+$ ]] || LAST_OFFSET=0

CURRENT_SIZE="$(wc -c < "$AMBIENT_LOG" | xargs)"
if [[ "$CURRENT_SIZE" -lt "$LAST_OFFSET" ]]; then
    # File rotated/truncated since last tick — restart from top.
    LAST_OFFSET=0
fi
[[ "$CURRENT_SIZE" -le "$LAST_OFFSET" ]] && exit 0

NEW_LINES="$(tail -c "+$((LAST_OFFSET + 1))" "$AMBIENT_LOG")"

extract_field() {
    # extract_field <line> <field-name>
    echo "$1" | grep -o "\"$2\":\"[^\"]*\"" | head -1 | cut -d'"' -f4
}

while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    echo "$line" | grep -q '"kind":"pr_merged_to_main"' || continue

    PR_URL="$(extract_field "$line" pr_url)"
    COMMIT_SHA="$(extract_field "$line" commit_sha)"
    GAP_IDS="$(extract_field "$line" gap_ids_closed)"
    LANE_TAGS="$(extract_field "$line" lane_tags)"
    [[ -z "$LANE_TAGS" ]] && continue

    IFS=',' read -ra ROLES <<< "$LANE_TAGS"
    for role in "${ROLES[@]}"; do
        [[ -z "$role" ]] && continue
        if [[ "$DRY_RUN" == 1 ]]; then
            echo "DRY-RUN: role=$role pr=$PR_URL sha=$COMMIT_SHA gaps=$GAP_IDS"
            continue
        fi
        MATCH_JSON="$(printf '{"ts":"%s","kind":"curator_lane_match","role":"%s","pr_url":"%s","commit_sha":"%s"}' \
            "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$role" "$PR_URL" "$COMMIT_SHA")"
        # scanner-anchor: "kind":"curator_lane_match"
        _ambient_write "$AMBIENT_LOG" "$MATCH_JSON"

        chump curator refresh "$role" \
            --pr-url "$PR_URL" \
            --commit-sha "$COMMIT_SHA" \
            --gap-ids "$GAP_IDS" \
            >/dev/null 2>&1 || echo "[WARN] post-merge-bell: chump curator refresh $role failed for $COMMIT_SHA" >&2
    done
done <<< "$NEW_LINES"

if [[ "$DRY_RUN" != 1 ]]; then
    echo "$CURRENT_SIZE" > "$BOOKMARK_FILE"
fi
