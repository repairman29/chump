#!/usr/bin/env bash
# velocity-trending.sh — INFRA-901
#
# Reads fleet_metrics_snapshot events from ambient.jsonl over the last 7 days,
# prints a text table of ship_rate and waste_rate per day, and emits
# kind=velocity_trend_computed with trend classification.
#
# Usage:
#   velocity-trending.sh [--window DAYS] [--dry-run] [--json]
#
# Options:
#   --window DAYS   Look-back window in days (default: 7)
#   --dry-run       Compute and print, do NOT emit to ambient.jsonl
#   --json          Output event JSON to stdout (in addition to table)
#
# Environment:
#   REPO_ROOT           Repo root (default: auto-detected)
#   CHUMP_AMBIENT_LOG   Path to ambient.jsonl
#   DRY_RUN             If "1", suppress ambient write

set -euo pipefail

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}"
AMB="${CHUMP_AMBIENT_LOG:-$REPO_ROOT/.chump-locks/ambient.jsonl}"
WINDOW_DAYS=7
DRY_RUN="${DRY_RUN:-0}"
JSON_OUT=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --window)  WINDOW_DAYS="$2"; shift 2 ;;
        --dry-run) DRY_RUN=1; shift ;;
        --json)    JSON_OUT=1; shift ;;
        -h|--help)
            grep '^#' "$0" | head -20 | sed 's/^# \?//'
            exit 0 ;;
        *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
done

_ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# ── Compute trend via python3 ─────────────────────────────────────────────────
RESULT=$(python3 - <<PYEOF
import json, os, sys
from datetime import datetime, timezone, timedelta
from collections import defaultdict

amb_path   = "$AMB"
window_days = int("$WINDOW_DAYS")
now        = datetime.now(timezone.utc)
cutoff     = now - timedelta(days=window_days)

def parse_ts(s):
    try:
        return datetime.fromisoformat(s.rstrip("Z")).replace(tzinfo=timezone.utc)
    except Exception:
        return None

# Read fleet_metrics_snapshot events in window
snapshots = []
if os.path.exists(amb_path):
    with open(amb_path) as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                ev = json.loads(line)
                if ev.get("kind") != "fleet_metrics_snapshot":
                    continue
                ts = parse_ts(ev.get("ts", ""))
                if ts and ts >= cutoff:
                    snapshots.append((ts, ev))
            except Exception:
                pass

# Group by day (UTC date string)
by_day = defaultdict(list)
for ts, ev in snapshots:
    day = ts.strftime("%Y-%m-%d")
    by_day[day].append(ev)

# For each day, take latest snapshot's values
days_sorted = sorted(by_day.keys())
daily = []
for day in days_sorted:
    evs = by_day[day]
    latest = sorted(evs, key=lambda e: e.get("ts", ""))[-1]
    daily.append({
        "day":           day,
        "ship_rate":     float(latest.get("ship_rate_24h", 0)),
        "waste_rate":    float(latest.get("waste_rate_24h", 0)),
        "active_gaps":   int(latest.get("active_gaps", 0)),
        "p0_count":      int(latest.get("p0_count", 0)),
    })

# Print text table
print("=== Fleet velocity (last {} days) ===".format(window_days))
print("{:<12} {:>10} {:>12} {:>12} {:>8}".format(
    "Date", "ship_rate", "waste_rate", "active_gaps", "P0s"))
print("-" * 58)
for d in daily:
    print("{:<12} {:>9.1%} {:>12.3f} {:>12d} {:>8d}".format(
        d["day"], d["ship_rate"], d["waste_rate"],
        d["active_gaps"], d["p0_count"]))
if not daily:
    print("  (no fleet_metrics_snapshot events in window)")

# Compute 7d aggregates
ship_rates  = [d["ship_rate"]  for d in daily]
waste_rates = [d["waste_rate"] for d in daily]

ship_rate_7d  = sum(ship_rates)  / len(ship_rates)  if ship_rates  else 0.0
waste_rate_7d = sum(waste_rates) / len(waste_rates) if waste_rates else 0.0

# Trend: compare avg of last 3 days vs prior 4 days
if len(daily) >= 4:
    recent3 = daily[-3:]
    prior4  = daily[:-3]
    recent_ship  = sum(d["ship_rate"]  for d in recent3) / len(recent3)
    prior_ship   = sum(d["ship_rate"]  for d in prior4)  / len(prior4)
    # improving: ship_rate up > 5%; degrading: down > 5%
    delta = recent_ship - prior_ship
    if delta > 0.05:
        trend = "improving"
    elif delta < -0.05:
        trend = "degrading"
    else:
        trend = "stable"
else:
    trend = "stable"

print()
print("7d avg  ship_rate={:.1%}  waste_rate={:.3f}  trend={}".format(
    ship_rate_7d, waste_rate_7d, trend))

# Output machine-readable result for shell to capture
import json as _json
print("__RESULT__:" + _json.dumps({
    "ship_rate_7d":  round(ship_rate_7d, 4),
    "waste_rate_7d": round(waste_rate_7d, 4),
    "trend":         trend,
    "days_sampled":  len(daily),
}))
PYEOF
)

# Extract machine-readable result line
TREND_JSON=$(printf '%s' "$RESULT" | grep "^__RESULT__:" | sed 's/^__RESULT__://')
TABLE=$(printf '%s' "$RESULT" | grep -v "^__RESULT__:")

printf '%s\n' "$TABLE"

# ── Build and emit ambient event ──────────────────────────────────────────────
TS="$(_ts)"
HOST="${HOSTNAME:-$(hostname 2>/dev/null || echo unknown)}"

EVENT=$(python3 - <<PYEOF
import json
m = $TREND_JSON
ev = {
    "ts":            "$TS",
    "kind":          "velocity_trend_computed",
    "window_days":   $WINDOW_DAYS,
    "ship_rate_7d":  m["ship_rate_7d"],
    "waste_rate_7d": m["waste_rate_7d"],
    "trend":         m["trend"],
    "days_sampled":  m["days_sampled"],
    "host":          "$HOST",
}
print(json.dumps(ev))
PYEOF
)

if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "[dry-run] would emit: $EVENT" >&2
else
    mkdir -p "$(dirname "$AMB")"
    printf '%s\n' "$EVENT" >> "$AMB"
fi

if [[ "$JSON_OUT" -eq 1 ]]; then
    printf '%s\n' "$EVENT"
fi
