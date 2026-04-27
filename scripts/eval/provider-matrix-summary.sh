#!/usr/bin/env bash
# provider-matrix-summary.sh — EVAL-089
#
# Aggregate the JSON status rows written by provider-matrix.sh into a
# human-readable verdict table. Reads .chump/bakeoff/<GAP-ID>/*.json.
#
# Usage:
#   scripts/eval/provider-matrix-summary.sh <GAP-ID>
#   scripts/eval/provider-matrix-summary.sh <GAP-ID> --json   # raw JSON array
#
# Verdict legend:
#   ship          — agent opened a PR (model + provider both worked)
#   exit0_no_pr   — agent gave up cleanly without shipping (model verdict: weak)
#   tool_storm    — circuit-breaker tripped on bad tool inputs (model verdict: bad tool calls)
#   rate_limited  — provider returned 429 (NOT a model verdict — retry later)
#   error         — infra failure (worktree/claim/process — fix and rerun)
#   skip          — provider config absent in .env

set -euo pipefail

usage() {
  cat >&2 <<EOF
Usage: $(basename "$0") <GAP-ID> [--json]

Reads .chump/bakeoff/<GAP-ID>/*.json and prints a verdict table.
EOF
  exit 2
}

[[ $# -ge 1 ]] || usage
GAP_ID="$1"
shift
FORMAT="table"
if [[ "${1:-}" == "--json" ]]; then
  FORMAT="json"
  shift
fi

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || {
  echo "[summary] must run inside a git checkout" >&2
  exit 1
}
DIR="$REPO_ROOT/.chump/bakeoff/$GAP_ID"
[[ -d "$DIR" ]] || {
  echo "[summary] no results dir for $GAP_ID at $DIR" >&2
  echo "[summary] run scripts/eval/provider-matrix.sh $GAP_ID first" >&2
  exit 1
}

shopt -s nullglob
files=("$DIR"/*.json)
shopt -u nullglob
if [[ ${#files[@]} -eq 0 ]]; then
  echo "[summary] no JSON status files in $DIR" >&2
  exit 1
fi

if [[ "$FORMAT" == "json" ]]; then
  jq -s '.' "${files[@]}"
  exit 0
fi

# Compact verdict table. Sort by outcome rank (ship > exit0_no_pr > tool_storm > rate_limited > error > skip),
# then by provider name.
jq -r '
  def rank:
    if .outcome == "ship" then 0
    elif .outcome == "exit0_no_pr" then 1
    elif .outcome == "tool_storm" then 2
    elif .outcome == "rate_limited" then 3
    elif .outcome == "error" then 4
    else 5 end;
  [rank, .provider, .model, .outcome, .elapsed_seconds, .detail] | @tsv
' "${files[@]}" \
  | sort -k1,1n -k2,2 \
  | awk -F'\t' 'BEGIN {
      printf "%-13s  %-50s  %-13s  %5s  %s\n", "PROVIDER", "MODEL", "OUTCOME", "SEC", "DETAIL"
      printf "%-13s  %-50s  %-13s  %5s  %s\n", "------------", "--------------------------------------------------", "-------------", "-----", "------"
    }
    { printf "%-13s  %-50s  %-13s  %5s  %s\n", $2, substr($3,1,50), $4, $5, $6 }'

# Footer: counts per outcome. Useful for "did anyone ship?" at-a-glance.
echo
jq -r '.outcome' "${files[@]}" | sort | uniq -c | awk '{ printf "  %2d  %s\n", $1, $2 }'
