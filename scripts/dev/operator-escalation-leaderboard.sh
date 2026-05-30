#!/usr/bin/env bash
# scripts/dev/operator-escalation-leaderboard.sh — META-207
#
# Audit leaderboard for kind=operator_escalation_unjustified events.
# Counts per-role per-day; prints top-3 offenders.
#
# Usage:
#   bash scripts/dev/operator-escalation-leaderboard.sh [--window 24h|7d|30d]

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
AMBIENT="$REPO_ROOT/.chump-locks/ambient.jsonl"
WINDOW="${2:-24h}"

if [[ ! -f "$AMBIENT" ]]; then
  echo "[escalation-leaderboard] no ambient.jsonl at $AMBIENT" >&2
  exit 0
fi

# Compute cutoff in ISO 8601 (bash 3.2 friendly — date math via Python fallback if needed)
case "$WINDOW" in
  24h) CUTOFF="$(date -u -v-24H +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d '-24 hours' +%Y-%m-%dT%H:%M:%SZ)" ;;
  7d)  CUTOFF="$(date -u -v-7d +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d '-7 days' +%Y-%m-%dT%H:%M:%SZ)" ;;
  30d) CUTOFF="$(date -u -v-30d +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d '-30 days' +%Y-%m-%dT%H:%M:%SZ)" ;;
  *)   echo "[escalation-leaderboard] unknown window: $WINDOW (use 24h/7d/30d)" >&2; exit 2 ;;
esac

echo "[escalation-leaderboard] window=$WINDOW since=$CUTOFF"
echo ""
echo "Top 3 roles by unjustified escalation count:"
grep -F '"kind":"operator_escalation_unjustified"' "$AMBIENT" 2>/dev/null \
  | awk -v cutoff="$CUTOFF" -F'"ts":"' '{split($2, a, "\""); if (a[1] >= cutoff) print $0}' \
  | grep -oE '"role":"[^"]*"' \
  | sort | uniq -c | sort -rn | head -3 \
  | awk '{printf "  %3d  %s\n", $1, $2}'

TOTAL="$(grep -F '"kind":"operator_escalation_unjustified"' "$AMBIENT" 2>/dev/null | wc -l | tr -d ' ')"
echo ""
echo "Total unjustified escalations in ambient (all-time): $TOTAL"
echo "SLO target: < 1 per fleet-day"
