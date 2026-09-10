#!/usr/bin/env bash
# scripts/ops/lib/merge-timeline.sh — RESILIENT: the durability gauge's
# canonical PRODUCTIVE-ACTION timeline.
#
# "Productive action" for the fleet is a MERGE to origin/main — the one signal
# that is node-agnostic ground truth (a merge landed no matter which Oracle/Mac
# node produced it) and is exactly what ATC watches (`git log origin/main
# --since=1h`) and what vital-signs' merge_throughput sign counts. The Mac's
# .chump-locks/ambient.jsonl does NOT carry gap_shipped/ship_landed events (the
# fleet runs on cuphead/mugman now), so ambient alone would under-count
# production to zero. This lib reads the merge TIMELINE (sorted merge
# timestamps), the shape the stall math needs — merges-24h.sh returns only a
# COUNT, so this is its timeline sibling, cache-first on the same DB.
#
# Cache-first per INFRA-1081: reads .chump/github_cache.db (webhook-fed) when
# present, falls back to `gh pr list` on cold/missing cache — mirroring
# merges-24h.sh's fallback chain.
#
# Usage (sourced):
#   source scripts/ops/lib/merge-timeline.sh
#   merge_timeline "$REPO_ROOT" "$GH_REPO" "$SINCE_ISO"   # -> sorted ISO ts, one per line
#
# Usage (direct):
#   scripts/ops/lib/merge-timeline.sh <repo_root> <gh_repo> <since_iso>
set -uo pipefail

# merge_timeline <repo_root> <gh_repo> <since_iso8601> -> prints merged-at
# timestamps (ISO8601 Z), one per line, ascending, for PRs merged at/after
# <since_iso>. Empty output = no merges in window (an honest silence).
merge_timeline() {
  local repo_root="${1:?merge_timeline: repo_root required}"
  local gh_repo="${2:?merge_timeline: gh_repo required}"
  local since="${3:-1970-01-01T00:00:00Z}"

  local db="$repo_root/.chump/github_cache.db"
  local stale_secs="${MERGE_TIMELINE_STALE_SECS:-7200}"  # 2h freshness bound
  if [[ -f "$db" ]] && command -v sqlite3 >/dev/null 2>&1; then
    local rows
    rows="$(sqlite3 "$db" \
      "SELECT merged_at FROM pr_state WHERE merged_at IS NOT NULL AND merged_at >= '$since' ORDER BY merged_at ASC;" \
      2>/dev/null)"
    if [[ -n "$rows" ]]; then
      # Positive cache result is trusted unconditionally (real merges can't be
      # faked into existence). Print and return.
      printf '%s\n' "$rows"
      return 0
    fi
    # Empty result: only trust it when the cache is FRESH — a dead webhook
    # receiver returns an empty set that is indistinguishable from a real
    # stall, and the durability gauge must not read a receiver outage as a
    # 100h stall. Fall through to a live gh query when the cache is stale.
    local db_mtime now age
    db_mtime="$(stat -f %m "$db" 2>/dev/null || stat -c %Y "$db" 2>/dev/null || echo 0)"
    now="$(date -u +%s)"
    age=$(( now - db_mtime ))
    if (( age <= stale_secs )); then
      # Fresh cache genuinely reporting no merges in window — honest empty.
      return 0
    fi
  fi

  # gh fallback (cold/stale/missing cache). Background-tagged so a durability
  # poll never starves a ship-blocking merge of the GraphQL bucket.
  command -v gh >/dev/null 2>&1 || return 0
  CHUMP_GH_CALL_CRITICALITY=background gh pr list --repo "$gh_repo" \
    --state merged --limit "${MERGE_TIMELINE_LIMIT:-400}" \
    --json mergedAt \
    --jq "[.[] | select(.mergedAt >= \"$since\") | .mergedAt] | sort | .[]" \
    2>/dev/null || true
}

if [[ "${BASH_SOURCE[0]:-$0}" == "${0}" ]]; then
  merge_timeline "${1:-.}" "${2:-repairman29/chump}" "${3:-1970-01-01T00:00:00Z}"
fi
