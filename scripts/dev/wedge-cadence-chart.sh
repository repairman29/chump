#!/usr/bin/env bash
# scripts/dev/wedge-cadence-chart.sh — MISSION-006 D3
#
# Generates a 30-day PR-cadence visualization annotated with wedge events.
# Output formats: --svg (default, embeddable), --json (raw data), --tty (ASCII for terminal).
#
# A "wedge event" is a 2+ hour window where ZERO PRs merged to origin/main
# despite open PRs existing during that window. Recovery time = (next merge time
# after wedge start) - (wedge start). Trend should drop over time as substrate
# hardens.
#
# Usage:
#   bash scripts/dev/wedge-cadence-chart.sh [--days N] [--svg|--json|--tty]
#
# Output:
#   docs/marketing/pr-cadence-30d.svg (default)
#   stdout (json or tty)

set -uo pipefail

DAYS=30
FORMAT=svg
WEDGE_THRESHOLD_HOURS=2

while [[ $# -gt 0 ]]; do
    case "$1" in
        --days) shift; DAYS="$1" ;;
        --days=*) DAYS="${1#*=}" ;;
        --svg) FORMAT=svg ;;
        --json) FORMAT=json ;;
        --tty) FORMAT=tty ;;
        --wedge-threshold-hours) shift; WEDGE_THRESHOLD_HOURS="$1" ;;
        --help|-h)
            head -25 "$0" | grep '^#' | sed 's/^# //; s/^#//'
            exit 0
            ;;
    esac
    shift
done

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$REPO_ROOT" || exit 1

# Collect merge data: one line per merge: timestamp,sha,subject
SINCE_ISO="$(date -u -v-${DAYS}d +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || \
              date -u --date="${DAYS} days ago" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)"

DATA="$(git log origin/main --since="$SINCE_ISO" --format='%cI|%h|%s' 2>/dev/null)"
if [[ -z "$DATA" ]]; then
    echo "ERROR: no merge data in last $DAYS days" >&2
    exit 1
fi

# Use python for the heavy lifting (datetime math + JSON/SVG output)
python3 <<PYEOF
import sys
import re
from datetime import datetime, timedelta, timezone

# Parse merge events from stdin-like data passed via env
data = """$DATA"""
events = []
for line in data.strip().split("\n"):
    if "|" not in line:
        continue
    parts = line.split("|", 2)
    if len(parts) < 3:
        continue
    ts_str, sha, subj = parts
    # Parse %cI ISO 8601 with timezone
    try:
        ts = datetime.fromisoformat(ts_str.replace("Z", "+00:00"))
        if ts.tzinfo is None:
            ts = ts.replace(tzinfo=timezone.utc)
    except ValueError:
        continue
    events.append((ts, sha, subj))

events.sort(key=lambda x: x[0])

if not events:
    print("ERROR: no parseable events", file=sys.stderr)
    sys.exit(1)

# Detect wedges: windows >= WEDGE_THRESHOLD_HOURS with no merges
THRESHOLD = timedelta(hours=$WEDGE_THRESHOLD_HOURS)
wedges = []
for i in range(len(events) - 1):
    gap = events[i + 1][0] - events[i][0]
    if gap >= THRESHOLD:
        wedges.append({
            "start": events[i][0].isoformat(),
            "end": events[i + 1][0].isoformat(),
            "duration_hours": round(gap.total_seconds() / 3600, 2),
            "recovery_commit": events[i + 1][1],
            "recovery_subject": events[i + 1][2][:80],
        })

# Daily merge counts
day_counts = {}
for ts, _, _ in events:
    day = ts.date().isoformat()
    day_counts[day] = day_counts.get(day, 0) + 1

# Trend: recent (last 7d) vs older (8-30d) recovery times
recent_wedges = [w for w in wedges if datetime.fromisoformat(w["start"]).date() >= (datetime.now(timezone.utc).date() - timedelta(days=7))]
older_wedges = [w for w in wedges if datetime.fromisoformat(w["start"]).date() < (datetime.now(timezone.utc).date() - timedelta(days=7))]

avg_recent = sum(w["duration_hours"] for w in recent_wedges) / max(len(recent_wedges), 1)
avg_older = sum(w["duration_hours"] for w in older_wedges) / max(len(older_wedges), 1)

import json
summary = {
    "window_days": $DAYS,
    "total_merges": len(events),
    "merges_per_day_avg": round(len(events) / max($DAYS, 1), 2),
    "wedges_detected": len(wedges),
    "wedge_threshold_hours": $WEDGE_THRESHOLD_HOURS,
    "avg_wedge_duration_recent_7d": round(avg_recent, 2),
    "avg_wedge_duration_older_8_30d": round(avg_older, 2),
    "trend": "improving" if avg_recent < avg_older else ("stable" if abs(avg_recent - avg_older) < 0.5 else "worsening"),
    "wedges": wedges[-10:],  # last 10 wedges
    "daily_counts": dict(sorted(day_counts.items())[-30:]),
}

format = "$FORMAT"

if format == "json":
    print(json.dumps(summary, indent=2))
elif format == "tty":
    print(f"=== PR Cadence — last {$DAYS} days ===")
    print(f"Total merges:        {summary['total_merges']} ({summary['merges_per_day_avg']}/day avg)")
    print(f"Wedges (>{$WEDGE_THRESHOLD_HOURS}h zero-merge): {summary['wedges_detected']}")
    print(f"Avg wedge duration:")
    print(f"  Last 7d:           {summary['avg_wedge_duration_recent_7d']}h")
    print(f"  Days 8-30:         {summary['avg_wedge_duration_older_8_30d']}h")
    print(f"  Trend:             {summary['trend']}")
    print()
    print("Recent wedges (last 10):")
    for w in summary["wedges"]:
        print(f"  {w['start'][:19]} → {w['end'][:19]}  {w['duration_hours']}h  recovery: {w['recovery_subject']}")
    print()
    print("Daily merge counts (last 30 days, sparkline):")
    days = sorted(summary['daily_counts'].keys())
    counts = [summary['daily_counts'][d] for d in days]
    max_c = max(counts) if counts else 1
    bars = " ▁▂▃▄▅▆▇█"
    for d, c in zip(days, counts):
        idx = min(int(c / max_c * (len(bars) - 1)), len(bars) - 1)
        print(f"  {d}  {bars[idx]} {c}")
elif format == "svg":
    # Minimal-dep SVG: bar chart with wedge annotations
    width = 800
    height = 300
    margin = 40
    days = sorted(summary['daily_counts'].keys())
    counts = [summary['daily_counts'][d] for d in days]
    max_c = max(counts) if counts else 1
    n = len(days) or 1
    bar_w = (width - 2 * margin) / n

    svg = [f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {width} {height}">']
    svg.append(f'<style>text {{ font: 10px sans-serif; fill: #333; }} .bar {{ fill: #4a9eff; }} .wedge {{ fill: #ff6b6b; opacity: 0.3; }} .title {{ font: bold 14px sans-serif; }} .trend {{ font: 12px sans-serif; fill: #2a7a2a; }}</style>')
    svg.append(f'<rect width="{width}" height="{height}" fill="white"/>')
    svg.append(f'<text x="{margin}" y="20" class="title">PR Cadence — last {$DAYS} days ({summary["total_merges"]} merges, {summary["wedges_detected"]} wedges)</text>')

    # Wedge annotations (red rectangles spanning the wedge duration)
    if days:
        start_day = datetime.fromisoformat(days[0] + "T00:00:00+00:00")
        end_day = datetime.fromisoformat(days[-1] + "T23:59:59+00:00")
        total_secs = max((end_day - start_day).total_seconds(), 1)
        for w in summary["wedges"]:
            try:
                ws = datetime.fromisoformat(w["start"])
                we = datetime.fromisoformat(w["end"])
                x1 = margin + ((ws - start_day).total_seconds() / total_secs) * (width - 2 * margin)
                x2 = margin + ((we - start_day).total_seconds() / total_secs) * (width - 2 * margin)
                svg.append(f'<rect class="wedge" x="{x1:.1f}" y="{margin}" width="{max(x2-x1, 2):.1f}" height="{height - 2*margin}"/>')
            except Exception:
                pass

    # Daily bars
    for i, (d, c) in enumerate(zip(days, counts)):
        x = margin + i * bar_w
        bar_h = (c / max_c) * (height - 2 * margin)
        svg.append(f'<rect class="bar" x="{x:.1f}" y="{height - margin - bar_h:.1f}" width="{max(bar_w - 1, 1):.1f}" height="{bar_h:.1f}"/>')

    # Trend text
    svg.append(f'<text x="{margin}" y="{height - 10}" class="trend">Trend: {summary["trend"]} (recent 7d avg wedge {summary["avg_wedge_duration_recent_7d"]}h vs older {summary["avg_wedge_duration_older_8_30d"]}h)</text>')
    svg.append('</svg>')

    import os
    out_dir = os.path.join("$REPO_ROOT", "docs", "marketing")
    os.makedirs(out_dir, exist_ok=True)
    out_path = os.path.join(out_dir, "pr-cadence-30d.svg")
    with open(out_path, "w") as f:
        f.write("\n".join(svg))
    print(f"wrote {out_path}")
    print(f"summary: {summary['total_merges']} merges, {summary['wedges_detected']} wedges, trend={summary['trend']}")
PYEOF
