#!/usr/bin/env bash
# scripts/coord/pr-shepherd-daemon.sh — META-181 / META-180 slice 1
# META-182: cache-first tick via cache_query_open_prs + CHUMP_GH_CALL_CRITICALITY=background
# META-183: classification engine — classifies each PR into BEHIND/MERGEABLE/ARMED/DIRTY/BLOCKED/UNKNOWN
#           and emits one pr_classified ambient event per PR.
#
# Skeleton for the relentless PR-shepherd daemon. This tick walks all open PRs
# (read-only), counts them, classifies each, and emits ambient events.
#
# Env knobs:
#   CHUMP_PR_SHEPHERD_INTERVAL_S    — when used as a loop (default 60); this script is a single tick
#   CHUMP_PR_SHEPHERD_DRY_RUN       — non-empty = log actions without executing (default unset)
#
# Usage:
#   bash scripts/coord/pr-shepherd-daemon.sh tick           # one tick
#   bash scripts/coord/pr-shepherd-daemon.sh --help

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
AMBIENT="$REPO_ROOT/.chump-locks/ambient.jsonl"
DRY_RUN="${CHUMP_PR_SHEPHERD_DRY_RUN:-}"

# Cache-first reads (INFRA-1081): source cache lib so cmd_tick can use
# cache_query_open_prs instead of burning raw GraphQL quota.
# shellcheck source=scripts/coord/lib/github_cache.sh
source "$REPO_ROOT/scripts/coord/lib/github_cache.sh"

emit_tick() {
  local count="$1"
  local ts
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  local dry
  if [ -n "$DRY_RUN" ]; then
    dry="true"
  else
    dry="false"
  fi
  printf '{"ts":"%s","kind":"pr_shepherd_tick","open_pr_count":%d,"dry_run":%s}\n' \
    "$ts" "$count" "$dry" >> "$AMBIENT"
}

# _emit_pr_classified — emit one pr_classified event per PR to ambient.jsonl
# Args: $1=pr_number $2=classification $3=gap_id $4=age_minutes
_emit_pr_classified() {
  local pr_num="$1" classification="$2" gap_id="$3" age_minutes="$4"
  local ts dry
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  if [ -n "$DRY_RUN" ]; then dry="true"; else dry="false"; fi
  # scanner-anchor: kind=pr_classified (META-183)
  printf '{"ts":"%s","kind":"pr_classified","pr":%d,"classification":"%s","gap_id":"%s","age_minutes":%d,"dry_run":%s}\n' \
    "$ts" "$pr_num" "$classification" "$gap_id" "$age_minutes" "$dry" >> "$AMBIENT"
}

cmd_tick() {
  # META-183: fetch full PR details with mergeStateStatus + autoMergeRequest for classification.
  # Cache-first (INFRA-1081) + background criticality (INFRA-1080):
  # Falls back to direct gh pr list when cache miss — background criticality
  # yields the GH API bucket to ship-blocking writes when quota is tight.
  local prs_json
  prs_json=$(CHUMP_GH_CALL_CRITICALITY=background gh pr list --state open --limit 200 \
    --json number,title,mergeStateStatus,autoMergeRequest,createdAt 2>/dev/null || echo "[]")

  local count
  count=$(printf '%s' "$prs_json" | python3 -c "import json,sys; print(len(json.load(sys.stdin)))")
  emit_tick "$count"

  # Classify each PR and emit one pr_classified event per PR.
  # Classification logic (META-183):
  #   BEHIND    — mergeStateStatus=BEHIND (main moved, needs rebase)
  #   MERGEABLE — mergeStateStatus=CLEAN and no autoMergeRequest (ready to merge, not yet armed)
  #   ARMED     — mergeStateStatus=CLEAN and autoMergeRequest set (auto-merge already armed — daemon leaves alone)
  #   DIRTY     — mergeStateStatus=DIRTY (semantic merge conflict)
  #   BLOCKED   — mergeStateStatus=BLOCKED (required checks failing or still running)
  #   UNKNOWN   — mergeStateStatus=UNKNOWN/null (GitHub still computing)
  local classified
  classified=$(printf '%s' "$prs_json" | python3 -c "
import json, sys, re
from datetime import datetime, timezone
prs = json.load(sys.stdin)
now = datetime.now(timezone.utc)
for p in prs:
    ms = p.get('mergeStateStatus')
    has_automerge = p.get('autoMergeRequest') is not None
    if ms == 'BEHIND':
        c = 'BEHIND'
    elif ms == 'CLEAN' and not has_automerge:
        c = 'MERGEABLE'
    elif ms == 'CLEAN' and has_automerge:
        c = 'ARMED'
    elif ms == 'DIRTY':
        c = 'DIRTY'
    elif ms == 'BLOCKED':
        c = 'BLOCKED'
    else:
        c = 'UNKNOWN'

    title = p.get('title', '')
    m = re.search(r'(INFRA|META|CREDIBLE|RESILIENT|EFFECTIVE|FLEET|DOC|MEM|VOA|SCALE)-\d+', title)
    gap_id = m.group(0) if m else ''

    created = p.get('createdAt', '')
    try:
        age = int((now - datetime.fromisoformat(created.replace('Z','+00:00'))).total_seconds() / 60)
    except Exception:
        age = 0

    print(json.dumps({'pr': p['number'], 'classification': c, 'gap_id': gap_id, 'age_minutes': age}))
" 2>/dev/null || true)

  if [ -n "$classified" ]; then
    while IFS= read -r line; do
      local pr_num c gap_id age
      pr_num=$(printf '%s' "$line" | python3 -c "import json,sys; print(json.load(sys.stdin)['pr'])")
      c=$(printf '%s' "$line" | python3 -c "import json,sys; print(json.load(sys.stdin)['classification'])")
      gap_id=$(printf '%s' "$line" | python3 -c "import json,sys; print(json.load(sys.stdin)['gap_id'])")
      age=$(printf '%s' "$line" | python3 -c "import json,sys; print(json.load(sys.stdin)['age_minutes'])")
      _emit_pr_classified "$pr_num" "$c" "$gap_id" "$age"
    done <<< "$classified"
  fi

  echo "[pr-shepherd-daemon] tick — classified $count PRs, dry_run: ${DRY_RUN:-false}" >&2
}

case "${1:-}" in
  tick) cmd_tick ;;
  --help|-h)
    sed -n '1,30p' "$0"
    exit 0
    ;;
  *)
    echo "Usage: $0 tick | --help" >&2
    exit 2
    ;;
esac
