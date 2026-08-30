#!/usr/bin/env bash
# scripts/ops/lib/merges-24h.sh — INFRA-3843 (parent INFRA-3841 "reconcile 1/9")
#
# The ONE computation of "merges in the last 24h" (canonical: merges_24h),
# shared by scripts/ops/vital-signs.sh (sign 1: merge_throughput),
# scripts/ops/faculty-collector.sh (faculty: build), and
# crates/chump-fleet-server/src/dashboard.rs (today_ships, via subprocess —
# Rust cannot `source` bash, so the Rust caller shells out to THIS script
# when it exists so all three still converge on one implementation). Before
# this gap the three had drifted: two independent inline `gh pr list`
# invocations with slightly different `--limit`/`--jq` cutoffs, plus a third,
# separate cache-first-then-gh implementation in Rust — three call sites that
# could silently disagree.
#
# Cache-first per INFRA-1081: reads .chump/github_cache.db (fed by the
# webhook receiver) when present, falls back to `gh pr list` on cold/missing
# cache. This mirrors dashboard.rs's own fallback chain exactly.
#
# Usage (sourced):
#   source scripts/ops/lib/merges-24h.sh
#   n="$(merges_24h "$REPO_ROOT" "$GH_REPO")"
#
# Usage (direct execution):
#   scripts/ops/lib/merges-24h.sh <repo_root> <gh_repo>
#   # -> prints the integer count to stdout
set -uo pipefail

# merges_24h <repo_root> <gh_repo> -> prints integer count of PRs merged in
# the trailing 24h window to stdout.
merges_24h() {
  local repo_root="${1:?merges_24h: repo_root required}"
  local gh_repo="${2:?merges_24h: gh_repo required}"
  local cutoff
  cutoff="$(date -u -d '24 hours ago' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -v-24H +%Y-%m-%dT%H:%M:%SZ)"

  local db="$repo_root/.chump/github_cache.db"
  if [[ -f "$db" ]] && command -v sqlite3 >/dev/null 2>&1; then
    local n
    n="$(sqlite3 "$db" \
      "SELECT COUNT(*) FROM pr_state WHERE merged_at IS NOT NULL AND merged_at >= '$cutoff';" \
      2>/dev/null)"
    if [[ "$n" =~ ^[0-9]+$ ]]; then
      printf '%s\n' "$n"
      return 0
    fi
  fi

  # Both cache and gh must be tried before giving up; on total failure print
  # nothing (not a fabricated 0) so callers can tell "no real source" apart
  # from "genuinely zero merges" — see HONESTY RULE in vital-signs.sh.
  local n
  n="$(gh pr list --repo "$gh_repo" --state merged --limit 300 --json mergedAt \
        --jq "[.[]|select(.mergedAt>\"$cutoff\")]|length" 2>/dev/null)"
  if [[ "$n" =~ ^[0-9]+$ ]]; then
    printf '%s\n' "$n"
  fi
}

# Allow direct execution as well as sourcing.
if [[ "${BASH_SOURCE[0]:-$0}" == "${0}" ]]; then
  merges_24h "${1:-.}" "${2:-repairman29/chump}"
fi
