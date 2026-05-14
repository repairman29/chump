#!/usr/bin/env bash
# scripts/coord/cooldown-scanner.sh — INFRA-1220
#
# Periodic scanner. Finds recently closed-not-merged PRs whose gap is still
# open, and stamps a cooldown for that gap. This is the auto-attached
# stamping path described by INFRA-1220 — fired by cron / launchd / a fleet
# tick rather than at the moment of close (we don't have a per-close hook
# yet, but we want the cooldown to fire promptly anyway).
#
# Usage:
#   scripts/coord/cooldown-scanner.sh                 # scan last 2h
#   scripts/coord/cooldown-scanner.sh --window 6h     # scan last 6h
#   scripts/coord/cooldown-scanner.sh --dry-run
#
# Idempotent: stamp_if_active() refuses to re-stamp a gap that already has
# an unexpired stamp (existing file is younger than the cooldown window).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC2034  # used by sourced gap-cooldown.sh
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd -P)"
# shellcheck disable=SC1091
source "$REPO_ROOT/scripts/coord/lib/gap-cooldown.sh"

WINDOW_DESC="2h"
DRY_RUN=0
while [ $# -gt 0 ]; do
    case "$1" in
        --window) WINDOW_DESC="$2"; shift 2 ;;
        --dry-run) DRY_RUN=1; shift ;;
        -h|--help) sed -n '2,15p' "$0" | sed 's/^# \?//'; exit 0 ;;
        *) echo "[cooldown-scanner] unknown arg: $1" >&2; exit 2 ;;
    esac
done

# Convert "2h" / "30m" / "1d" to a `gh search` --search predicate.
case "$WINDOW_DESC" in
    *h) hours="${WINDOW_DESC%h}";; *m) hours="$(( ${WINDOW_DESC%m} / 60 ))"; (( hours == 0 )) && hours=1 ;;
    *d) hours="$(( ${WINDOW_DESC%d} * 24 ))";;
    *) echo "[cooldown-scanner] bad --window '$WINDOW_DESC' (use Nh/Nm/Nd)" >&2; exit 2 ;;
esac

cutoff="$(date -u -v "-${hours}H" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || \
          date -u -d "-${hours} hours" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)"
[[ -z "$cutoff" ]] && { echo "[cooldown-scanner] could not compute cutoff time" >&2; exit 1; }

if ! command -v gh >/dev/null 2>&1; then
    echo "[cooldown-scanner] gh not installed; skipping" >&2
    exit 0
fi
if ! command -v chump >/dev/null 2>&1; then
    echo "[cooldown-scanner] chump CLI not installed; skipping" >&2
    exit 0
fi

repo="$(gh repo view --json nameWithOwner --jq '.nameWithOwner' 2>/dev/null)"
[[ -z "$repo" ]] && { echo "[cooldown-scanner] could not resolve repo" >&2; exit 1; }

# Pull closed-not-merged PRs since cutoff.
listing="$(gh api "repos/$repo/pulls?state=closed&per_page=100&sort=updated&direction=desc" \
    --jq ".[] | select(.merged_at == null) | select(.closed_at >= \"$cutoff\") | \"\(.number)|\(.closed_at)|\(.title)\"" \
    2>/dev/null)"
[[ -z "$listing" ]] && { echo "[cooldown-scanner] no closed-not-merged PRs since $cutoff"; exit 0; }

stamped=0
skipped=0
while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    pr_num="${line%%|*}"
    rest="${line#*|}"
    title="${rest#*|}"
    # Extract gap IDs from title; usually one but allow many.
    gap_ids="$(echo "$title" | grep -oE '[A-Z]+-[0-9]+' | sort -u)"
    [[ -z "$gap_ids" ]] && continue
    for gid in $gap_ids; do
        # Only stamp if gap is still status=open (otherwise it's a normal close-after-ship).
        status="$(chump gap show "$gid" 2>/dev/null | awk -F': *' '/^[[:space:]]*status:/ {print $2; exit}')"
        if [[ "$status" != "open" ]]; then
            skipped=$((skipped + 1))
            continue
        fi
        if gap_cooldown_active "$gid"; then
            skipped=$((skipped + 1))
            continue
        fi
        if [[ "$DRY_RUN" -eq 1 ]]; then
            echo "[cooldown-scanner] WOULD stamp $gid (from PR #$pr_num)"
        else
            gap_cooldown_stamp "$gid" "$pr_num" "auto-stamp:closed-not-merged"
            echo "[cooldown-scanner] stamped $gid (from PR #$pr_num)"
            stamped=$((stamped + 1))
        fi
    done
done <<< "$listing"

echo "[cooldown-scanner] window=$WINDOW_DESC stamped=$stamped already-current=$skipped"
exit 0
