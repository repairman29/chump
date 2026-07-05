#!/usr/bin/env bash
# scripts/ops/fleet-metrics-snapshot.sh — INFRA-900
#
# Reads ambient.jsonl + state.db and emits kind=fleet_metrics_snapshot with:
#   ts, ship_rate_24h, waste_rate_24h, cycle_time_p50_h,
#   active_gaps, p0_count
#
# ship_rate_24h    = pr_merged events / pr_opened events in window
#                    (falls back to gap_shipped count / session_start count)
# waste_rate_24h   = float from `chump waste-tally --window 24h --json`.waste_rate
# cycle_time_p50_h = P50 of (closed_at - created_at)/3600 for gaps closed in window
# active_gaps      = COUNT of status=open gaps in state.db
# p0_count         = COUNT of status=open AND priority=P0 gaps in state.db
#
# Usage:
#   bash scripts/ops/fleet-metrics-snapshot.sh
#   bash scripts/ops/fleet-metrics-snapshot.sh --json        # stdout JSON + emit
#   bash scripts/ops/fleet-metrics-snapshot.sh --dry-run     # print, skip emit
#   bash scripts/ops/fleet-metrics-snapshot.sh --window 48   # wider window (hours)
#
# Environment overrides (for testing):
#   CHUMP_AMBIENT_LOG   path to ambient.jsonl
#   CHUMP_STATE_DB      path to state.db
#   DRY_RUN             "1" to suppress ambient write (same as --dry-run)

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${REPO_ROOT:-$(cd "$SCRIPT_DIR/../.." && pwd)}"
AMB="${CHUMP_AMBIENT_LOG:-$REPO_ROOT/.chump-locks/ambient.jsonl}"
STATE_DB="${CHUMP_STATE_DB:-$REPO_ROOT/.chump/state.db}"
WINDOW_HOURS=24
DRY_RUN="${DRY_RUN:-0}"
JSON_OUT=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --window)   WINDOW_HOURS="$2"; shift 2 ;;
        --dry-run)  DRY_RUN=1; shift ;;
        --json)     JSON_OUT=1; shift ;;
        -h|--help)
            sed -n '/^# /p' "$0" | head -22 | sed 's/^# \?//'
            exit 0 ;;
        *) echo "fleet-metrics-snapshot: unknown option: $1" >&2; exit 1 ;;
    esac
done

_ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# ── 1. Parse ambient.jsonl for ship_rate_24h ─────────────────────────────────
SHIP_METRICS="$(python3 - "$AMB" "$WINDOW_HOURS" <<'PYEOF'
import sys, json
from datetime import datetime, timezone, timedelta

amb_path   = sys.argv[1]
window_h   = int(sys.argv[2])
now        = datetime.now(timezone.utc)
cutoff     = now - timedelta(hours=window_h)

def parse_ts(s):
    try:
        return datetime.fromisoformat(s.rstrip("Z")).replace(tzinfo=timezone.utc)
    except Exception:
        return None

pr_opened = 0
pr_merged = 0

try:
    with open(amb_path) as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                ev = json.loads(line)
            except Exception:
                continue
            ts = parse_ts(ev.get("ts", ""))
            if not ts or ts < cutoff:
                continue
            kind = ev.get("kind", "")
            if kind == "pr_opened":
                pr_opened += 1
            elif kind in ("pr_merged", "gap_shipped"):
                pr_merged += 1
            # fallback proxies
            elif ev.get("event") == "commit":
                pr_merged += 1
            elif kind == "session_start":
                pr_opened += 1
except FileNotFoundError:
    pass

if pr_opened > 0:
    ship_rate = round(pr_merged / pr_opened, 4)
elif pr_merged > 0:
    ship_rate = 1.0
else:
    ship_rate = 0.0

print(json.dumps({"ship_rate_24h": ship_rate, "pr_merged": pr_merged, "pr_opened": pr_opened}))
PYEOF
)"

ship_rate_24h="$(echo "$SHIP_METRICS" | python3 -c "import sys,json; print(json.load(sys.stdin)['ship_rate_24h'])")"

# ── 2. waste_rate_24h via chump waste-tally ──────────────────────────────────
waste_rate_24h=0.0
if command -v chump &>/dev/null; then
    wt_json="$(chump waste-tally --window "${WINDOW_HOURS}h" --json 2>/dev/null || echo '{}')"
    waste_rate_24h="$(printf '%s' "$wt_json" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    # prefer explicit waste_rate; fall back to total_events / 1000 as float proxy
    if 'waste_rate' in d:
        print(round(float(d['waste_rate']), 4))
    elif 'total_events' in d:
        print(round(float(d['total_events']), 4))
    else:
        print(0.0)
except Exception:
    print(0.0)
" 2>/dev/null || echo 0.0)"
fi

# ── 3. cycle_time_p50_h, active_gaps, p0_count from state.db ─────────────────
cycle_time_p50_h=0.0
active_gaps=0
p0_count=0

if [[ -f "$STATE_DB" ]] && command -v sqlite3 &>/dev/null; then
    NOW_EPOCH="$(date -u +%s)"
    CUTOFF_EPOCH=$(( NOW_EPOCH - WINDOW_HOURS * 3600 ))

    active_gaps="$(sqlite3 "$STATE_DB" \
        "SELECT COUNT(*) FROM gaps WHERE status='open';" 2>/dev/null || echo 0)"
    [[ -z "$active_gaps" ]] && active_gaps=0

    p0_count="$(sqlite3 "$STATE_DB" \
        "SELECT COUNT(*) FROM gaps WHERE status='open' AND priority='P0';" 2>/dev/null || echo 0)"
    [[ -z "$p0_count" ]] && p0_count=0

    # P50 via ordering: pick the middle row
    cycle_time_p50_h="$(sqlite3 "$STATE_DB" "
WITH durations AS (
    SELECT (closed_at - created_at) / 3600.0 AS h
    FROM gaps
    WHERE closed_at IS NOT NULL
      AND created_at IS NOT NULL
      AND closed_at > created_at
      AND closed_at >= $CUTOFF_EPOCH
    ORDER BY h
),
cnt AS (SELECT COUNT(*) AS n FROM durations)
SELECT ROUND(h, 2)
FROM durations, cnt
LIMIT 1 OFFSET MAX(0, (cnt.n - 1) / 2);
" 2>/dev/null || echo 0.0)"
    [[ -z "$cycle_time_p50_h" || "$cycle_time_p50_h" == "NULL" ]] && cycle_time_p50_h=0.0
fi

# ── 4. Build and emit event ───────────────────────────────────────────────────
TS="$(_ts)"

EVENT="$(python3 -c "
import json
ev = {
    'ts':               '$TS',
    'kind':             'fleet_metrics_snapshot',
    'ship_rate_24h':    $ship_rate_24h,
    'waste_rate_24h':   $waste_rate_24h,
    'cycle_time_p50_h': $cycle_time_p50_h,
    'active_gaps':      $active_gaps,
    'p0_count':         $p0_count,
    'window_h':         $WINDOW_HOURS,
}
print(json.dumps(ev))
")"

if [[ "$DRY_RUN" -eq 1 ]]; then
    printf '[fleet-metrics-snapshot] dry-run: %s\n' "$EVENT" >&2
else
    mkdir -p "$(dirname "$AMB")" 2>/dev/null || true
    printf '%s\n' "$EVENT" >> "$AMB"
fi

if [[ "$JSON_OUT" -eq 1 ]]; then
    printf '%s\n' "$EVENT"
else
    printf '[fleet-metrics-snapshot] ship_rate_24h=%s waste_rate_24h=%s cycle_time_p50_h=%s active_gaps=%s p0_count=%s\n' \
        "$ship_rate_24h" "$waste_rate_24h" "$cycle_time_p50_h" "$active_gaps" "$p0_count"
fi
