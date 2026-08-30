#!/usr/bin/env bash
# scripts/ops/lib/operator-pages-24h.sh — INFRA-3848 (parent INFRA-3841 "reconcile 5/9")
#
# The ONE computation of "operator pages in the last 24h" (canonical:
# operator_pages_24h), shared by scripts/ops/vital-signs.sh (sign
# human_intervention) and scripts/ops/faculty-collector.sh (faculty
# communicate). Before this gap the two had drifted onto different kind-sets:
# vital-signs counted {operator_page, operator_paged, pager_notified} while
# faculty-collector counted only {operator_paged} — so the same ambient log
# could report two different page counts depending which reader you asked.
# Canonical kind-set (the union, matching vital-signs' broader definition):
#   operator_page, operator_paged, pager_notified
#
# Usage (sourced):
#   source scripts/ops/lib/operator-pages-24h.sh
#   n="$(operator_pages_24h "$AMBIENT_LOG" "$CUTOFF_24H")"
#
# Usage (direct execution):
#   scripts/ops/lib/operator-pages-24h.sh <ambient_log> <cutoff_ts>
#   # -> prints the integer count to stdout
set -uo pipefail

# operator_pages_24h <ambient_log> <cutoff_ts_iso8601> -> prints integer
# count of operator-page events at/after cutoff to stdout.
operator_pages_24h() {
  local ambient_log="${1:?operator_pages_24h: ambient_log required}"
  local cutoff="${2:?operator_pages_24h: cutoff_ts required}"

  [[ -f "$ambient_log" ]] || { printf '0\n'; return 0; }

  local n
  n="$(grep -hE '"kind":"(operator_page|operator_paged|pager_notified)"' "$ambient_log" 2>/dev/null \
    | awk -v c="$cutoff" -F'"ts":"' '{split($2,a,"\""); if(a[1]>=c) n++} END{print n+0}')"
  [[ "$n" =~ ^[0-9]+$ ]] || n=0
  printf '%s\n' "$n"
}

# Allow direct execution as well as sourcing.
if [[ "${BASH_SOURCE[0]:-$0}" == "${0}" ]]; then
  operator_pages_24h "${1:-.chump-locks/ambient.jsonl}" "${2:-1970-01-01T00:00:00Z}"
fi
