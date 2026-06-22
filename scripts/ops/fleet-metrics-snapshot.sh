#!/usr/bin/env bash
# fleet-metrics-snapshot.sh — INFRA-900
#
# Reads ambient.jsonl + state.db and emits kind=fleet_metrics_snapshot with:
#   ts, ship_rate_24h, waste_rate_24h, cycle_time_p50_h,
#   active_gaps, p0_count
#
# Usage:
#   fleet-metrics-snapshot.sh [--window HOURS] [--dry-run] [--json]
#
# Options:
#   --window HOURS    Look-back window for PR/event stats (default: 24)
#   --dry-run         Print computed metrics, do NOT emit to ambient.jsonl
#   --json            Output JSON to stdout (in addition to ambient emit)
#
# Environment:
#   REPO_ROOT             Repo root (default: auto-detected)
#   CHUMP_AMBIENT_LOG     Path to ambient.jsonl
#   DRY_RUN               If "1", suppress ambient write (same as --dry-run)

set -euo pipefail

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}"
AMB="${CHUMP_AMBIENT_LOG:-$REPO_ROOT/.chump-locks/ambient.jsonl}"
WINDOW_HOURS=24
DRY_RUN="${DRY_RUN:-0}"
JSON_OUT=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --window)  WINDOW_HOURS="$2"; shift 2 ;;
        --dry-run) DRY_RUN=1; shift ;;
        --json)    JSON_OUT=1; shift ;;
        -h|--help)
            grep '^#' "$0" | head -20 | sed 's/^# \?//'
            exit 0 ;;
        *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
done

_ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# ── Compute metrics via python3 ───────────────────────────────────────────────
METRICS=$(python3 - <<PYEOF
import json, os, sys, subprocess, re
from datetime import datetime, timezone, timedelta

repo_root  = "$REPO_ROOT"
amb_path   = "$AMB"
window_h   = int("$WINDOW_HOURS")
now        = datetime.now(timezone.utc)
cutoff     = now - timedelta(hours=window_h)

# ── Helper: parse ISO timestamp ───────────────────────────────────────────────
def parse_ts(s):
    try:
        s = s.rstrip("Z")
        return datetime.fromisoformat(s).replace(tzinfo=timezone.utc)
    except Exception:
        return None

# ── Read ambient.jsonl ────────────────────────────────────────────────────────
events = []
if os.path.exists(amb_path):
    with open(amb_path) as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                ev = json.loads(line)
                ts = parse_ts(ev.get("ts", ""))
                if ts:
                    ev["_ts"] = ts
                    events.append(ev)
            except Exception:
                pass

recent = [e for e in events if e.get("_ts") and e["_ts"] >= cutoff]

# ── ship_rate_24h: merged PRs / opened PRs in window ─────────────────────────
pr_opened  = sum(1 for e in recent if e.get("kind") == "pr_opened")
pr_merged  = sum(1 for e in recent if e.get("kind") in ("pr_merged", "gap_shipped"))
if pr_opened > 0:
    ship_rate = round(pr_merged / pr_opened, 3)
else:
    # Fall back to counting gap_shipped events only
    ship_rate = min(1.0, pr_merged / max(1, pr_merged)) if pr_merged > 0 else 0.0

# ── waste_rate_24h: try chump waste-tally, fallback to ambient ────────────────
waste_rate = 0.0
try:
    result = subprocess.run(
        ["chump", "waste-tally", "--since", str(window_h) + "h", "--json"],
        capture_output=True, text=True, timeout=10
    )
    if result.returncode == 0 and result.stdout.strip():
        wdata = json.loads(result.stdout.strip())
        # waste-tally JSON exposes total_incidents and total_events.
        # Prefer explicit waste_rate field if present (e.g. test stubs).
        if "waste_rate" in wdata:
            waste_rate = float(wdata["waste_rate"])
        else:
            total_events = int(wdata.get("total_events", 0))
            total_incidents = int(wdata.get("total_incidents", 0))
            waste_rate = total_incidents / max(total_events, 1)
except Exception:
    # Fallback: count waste_logged events in ambient
    waste_events = [e for e in recent if e.get("kind") == "waste_logged"]
    waste_rate = len(waste_events) / max(1, window_h)  # events/hour as proxy

# ── cycle_time_p50_h: median (gap open → close) in hours ─────────────────────
cycle_times = []
gap_open_ts = {}  # gap_id -> open ts

for e in events:  # full history, not just recent
    kind = e.get("kind", "")
    gid  = e.get("gap_id") or e.get("id", "")
    ts   = e.get("_ts")
    if not ts:
        continue
    if kind in ("gap_claimed", "gap_opened") and gid:
        gap_open_ts.setdefault(gid, ts)
    elif kind in ("gap_shipped", "pr_merged") and gid:
        if gid in gap_open_ts:
            dt_h = (ts - gap_open_ts[gid]).total_seconds() / 3600.0
            if dt_h > 0:
                cycle_times.append(dt_h)

if cycle_times:
    cycle_times.sort()
    mid = len(cycle_times) // 2
    cycle_time_p50 = round(cycle_times[mid], 2)
else:
    cycle_time_p50 = 0.0

# ── active_gaps + p0_count from chump gap list ────────────────────────────────
active_gaps = 0
p0_count    = 0
try:
    result = subprocess.run(
        ["chump", "gap", "list", "--status", "open"],
        capture_output=True, text=True, timeout=15
    )
    if result.returncode == 0:
        for line in result.stdout.splitlines():
            line = line.strip()
            if line.startswith("[open]") or line.startswith("[claimed]"):
                active_gaps += 1
                if "(P0/" in line:
                    p0_count += 1
except Exception:
    pass

# ── Output JSON ───────────────────────────────────────────────────────────────
result = {
    "ship_rate_24h":    ship_rate,
    "waste_rate_24h":   waste_rate,
    "cycle_time_p50_h": cycle_time_p50,
    "active_gaps":      active_gaps,
    "p0_count":         p0_count,
}
print(json.dumps(result))
PYEOF
)

if [[ -z "$METRICS" ]]; then
    echo "Error: failed to compute metrics" >&2
    exit 1
fi

# ── Build ambient event ───────────────────────────────────────────────────────
TS="$(_ts)"
HOST="${HOSTNAME:-$(hostname 2>/dev/null || echo unknown)}"

EVENT=$(python3 - <<PYEOF
import json
m = $METRICS
ev = {
    "ts":               "$TS",
    "kind":             "fleet_metrics_snapshot",
    "ship_rate_24h":    m["ship_rate_24h"],
    "waste_rate_24h":   m["waste_rate_24h"],
    "cycle_time_p50_h": m["cycle_time_p50_h"],
    "active_gaps":      m["active_gaps"],
    "p0_count":         m["p0_count"],
    "window_h":         $WINDOW_HOURS,
    "host":             "$HOST",
}
print(json.dumps(ev))
PYEOF
)

# ── Emit to ambient.jsonl ─────────────────────────────────────────────────────
if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "[dry-run] would emit: $EVENT" >&2
else
    mkdir -p "$(dirname "$AMB")"
    printf '%s\n' "$EVENT" >> "$AMB"
fi

# ── JSON output to stdout ─────────────────────────────────────────────────────
if [[ "$JSON_OUT" -eq 1 ]]; then
    printf '%s\n' "$EVENT"
else
    python3 - <<PYEOF
import json
m = $METRICS
print(f"fleet metrics snapshot (window={int('$WINDOW_HOURS')}h):")
print(f"  ship_rate_24h    = {m['ship_rate_24h']:.1%}")
print(f"  waste_rate_24h   = {m['waste_rate_24h']:.3f}")
print(f"  cycle_time_p50_h = {m['cycle_time_p50_h']:.1f}h")
print(f"  active_gaps      = {m['active_gaps']}")
print(f"  p0_count         = {m['p0_count']}")
PYEOF
fi
