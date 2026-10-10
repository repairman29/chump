#!/usr/bin/env bash
# gap-flow-gauge.sh — RESILIENT-1437 AC5: publish open-gap count and
# created-per-day vs closed-per-day (trailing window) as a gap_flow_gauge
# ambient event. Read-only against state.db.
# Usage: gap-flow-gauge.sh [--days N] [--json]
set -euo pipefail
DAYS=7; JSON=0
while [[ $# -gt 0 ]]; do
  case "$1" in --days) DAYS="$2"; shift 2;; --json) JSON=1; shift;; *) shift;; esac
done
ROOT="${CHUMP_REPO:-$(git rev-parse --show-toplevel)}"
DB="${CHUMP_STATE_DB:-$ROOT/.chump/state.db}"
AMB="${CHUMP_AMBIENT_LOG:-$ROOT/.chump-locks/ambient.jsonl}"
[[ -f "$DB" ]] || { echo "gap-flow-gauge: no state.db at $DB" >&2; exit 0; }
q() { sqlite3 "$DB" "$1"; }
OPEN=$(q "SELECT COUNT(*) FROM gaps WHERE status='open';")
CREATED=$(q "SELECT COUNT(*) FROM gaps WHERE opened_date >= date('now','-${DAYS} days');")
CLOSED=$(q "SELECT COUNT(*) FROM gaps WHERE status='done' AND closed_date >= date('now','-${DAYS} days');")
SLICES=$(q "SELECT COUNT(*) FROM gaps WHERE status='open' AND title LIKE '%slice)';")
CPD=$(awk -v n="$CREATED" -v d="$DAYS" 'BEGIN{printf "%.1f", n/d}')
XPD=$(awk -v n="$CLOSED" -v d="$DAYS" 'BEGIN{printf "%.1f", n/d}')
OUT=$(printf '{"ts":"%s","kind":"gap_flow_gauge","source":"gap-flow-gauge.sh","window_days":%s,"open":%s,"open_slices":%s,"created_per_day":%s,"closed_per_day":%s}' \
  "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$DAYS" "$OPEN" "$SLICES" "$CPD" "$XPD")
mkdir -p "$(dirname "$AMB")" 2>/dev/null || true
echo "$OUT" >> "$AMB" 2>/dev/null || true
if [[ $JSON -eq 1 ]]; then echo "$OUT"; else
  echo "open=$OPEN open_slices=$SLICES created/day=$CPD closed/day=$XPD (${DAYS}d)"; fi
