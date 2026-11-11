#!/usr/bin/env bash
# node-output.sh — INFRA-8059: what did each node (esp. cloud agents) produce?
#
# Usage: scripts/dev/node-output.sh [--hours N] [--gap GAP-ID] [--ref REF]
#   Counts commits on REF (default origin/main) in the last N hours (default 24)
#   grouped by `Agent-Node:` trailer, plus ambient events grouped by `host`.
#   Cloud nodes match $CHUMP_CLOUD_NODE_PATTERN (default '^cloud-').
#   --gap shows which node(s) claimed/committed work for that gap.
set -euo pipefail
HOURS=24; GAP=""; REF="origin/main"
while [[ $# -gt 0 ]]; do
    case "$1" in
        --hours) HOURS="$2"; shift 2 ;;
        --gap) GAP="$2"; shift 2 ;;
        --ref) REF="$2"; shift 2 ;;
        *) echo "unknown arg: $1" >&2; exit 2 ;;
    esac
done
PAT="${CHUMP_CLOUD_NODE_PATTERN:-^cloud-}"
ROOT="$(git rev-parse --show-toplevel)"
COMMON="$(git rev-parse --git-common-dir)"
AMBIENT="${CHUMP_AMBIENT_LOG:-$(cd "$COMMON/.." && pwd)/.chump-locks/ambient.jsonl}"

if [[ -n "$GAP" ]]; then
    echo "== commits mentioning $GAP (node trailer) =="
    git log "$REF" -i --grep="$GAP" --format='%h %(trailers:key=Agent-Node,valueonly,separator=)' | sed 's/ $/ (no Agent-Node trailer)/'
    echo "== ambient events for $GAP by host =="
    [[ -f "$AMBIENT" ]] && grep -F "\"$GAP\"" "$AMBIENT" 2>/dev/null | grep -o '"host":"[^"]*"' | sort | uniq -c || true
    exit 0
fi

echo "== commits on $REF, last ${HOURS}h, by Agent-Node =="
git log "$REF" --since="${HOURS} hours ago" --format='%(trailers:key=Agent-Node,valueonly,separator=)' \
    | sed 's/^$/(unattributed)/' | sort | uniq -c | sort -rn | tee /tmp/node-output.$$ 
cloud_commits="$(awk -v p="$PAT" '{n=$2; if (n ~ p) s+=$1} END{print s+0}' /tmp/node-output.$$)"
rm -f /tmp/node-output.$$
echo "cloud-node commits (pattern $PAT): $cloud_commits"

echo "== ambient events by host (last ${HOURS}h) =="
if [[ -f "$AMBIENT" ]]; then
    since="$(date -u -d "${HOURS} hours ago" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -v-"${HOURS}"H +%Y-%m-%dT%H:%M:%SZ)"
    awk -v s="$since" -F'"ts":"' 'NF>1 && substr($2,1,20) >= s' "$AMBIENT" \
        | { grep -o '"host":"[^"]*"' || true; } | sort | uniq -c | sort -rn
else
    echo "(no ambient log)"
fi
