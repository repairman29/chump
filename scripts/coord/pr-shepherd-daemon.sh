#!/usr/bin/env bash
# scripts/coord/pr-shepherd-daemon.sh — META-181 / META-180 slice 1
# META-182: cache-first tick via cache_query_open_prs + CHUMP_GH_CALL_CRITICALITY=background
#
# Skeleton for the relentless PR-shepherd daemon. This tick walks all open PRs
# (read-only), counts them, and emits one ambient pr_shepherd_tick event with
# the count. Classification + action paths are downstream sub-gaps.
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

cmd_tick() {
  # Cache-first (INFRA-1081) + background criticality (INFRA-1080):
  # cache_query_open_prs reads from .chump/github_cache.db (SQLite) first,
  # falls back to a single REST call on miss — never burns GraphQL quota.
  # CHUMP_GH_CALL_CRITICALITY=background yields the GH API bucket to
  # ship-blocking writes (gh pr merge, gh pr create) when quota is tight.
  local count
  count=$(CHUMP_GH_CALL_CRITICALITY=background cache_query_open_prs 2>/dev/null | wc -l | tr -d ' ')
  emit_tick "$count"
  echo "[pr-shepherd-daemon] tick — open PRs: $count, dry_run: ${DRY_RUN:-false}" >&2
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
