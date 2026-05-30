#!/usr/bin/env bash
# scripts/coord/pr-shepherd-daemon.sh — META-181 / META-180 slice 1
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
  # Cache-first: prefer scripts/coord/lib/github_cache.sh if available
  # Raw gh pr list used here: META-181 skeleton; migration to chump_gh wrapper deferred to META-182 (cache-first integration)
  local count
  if command -v gh >/dev/null 2>&1; then
    count=$(gh pr list --state open --json number --jq 'length' 2>/dev/null || echo 0)
  else
    count=0
  fi
  emit_tick "$count"
  local dry_label
  if [ -n "$DRY_RUN" ]; then
    dry_label="true"
  else
    dry_label="false"
  fi
  echo "[pr-shepherd-daemon] tick — open PRs: $count, dry_run: $dry_label" >&2
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
