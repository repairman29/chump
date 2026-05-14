#!/usr/bin/env bash
# scripts/dev/cache-hit-rate.sh — CREDIBLE-064
#
# Prints the hourly cache_hit / (cache_hit + cache_miss) ratio per helper
# from the ambient.jsonl event stream.
#
# Usage:
#   bash scripts/dev/cache-hit-rate.sh [--window N]   # last N hours (default 24)
#   bash scripts/dev/cache-hit-rate.sh --json          # machine-readable JSON
#
# Output (human):
#   helper                       hits  misses  total  hit_rate%
#   cache_lookup_pr              47    12      59     79.7%
#   cache_lookup_checks          103   8       111    92.8%
#   cache_query_behind_prs       30    2       32     93.8%
#   OVERALL                      180   22      202    89.1%
#
# Exit 0 always — read-only report.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
AMBIENT="$REPO_ROOT/.chump-locks/ambient.jsonl"

WINDOW_H=24
AS_JSON=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --window) WINDOW_H="${2:?--window requires a value}"; shift 2 ;;
        --json)   AS_JSON=1; shift ;;
        -h|--help)
            echo "Usage: $0 [--window N] [--json]"
            echo "  --window N   look back N hours (default 24)"
            echo "  --json       output machine-readable JSON"
            exit 0
            ;;
        *) echo "unknown flag: $1" >&2; exit 1 ;;
    esac
done

if [[ ! -f "$AMBIENT" ]]; then
    echo "no ambient.jsonl found at $AMBIENT" >&2
    exit 0
fi

python3 - "$AMBIENT" "$WINDOW_H" "$AS_JSON" <<'PY'
import json, sys
from datetime import datetime, timezone, timedelta

ambient_path, window_h, as_json = sys.argv[1], int(sys.argv[2]), sys.argv[3] == "1"
cutoff = datetime.now(timezone.utc) - timedelta(hours=window_h)

hits = {}   # helper -> count
misses = {}  # helper -> count

with open(ambient_path, "r", errors="replace") as f:
    for line in f:
        try:
            e = json.loads(line.strip())
        except Exception:
            continue
        kind = e.get("kind", "")
        if kind not in ("cache_hit", "cache_miss"):
            continue
        try:
            ts = datetime.fromisoformat(e["ts"].replace("Z", "+00:00"))
        except Exception:
            continue
        if ts < cutoff:
            continue
        helper = e.get("helper", "unknown")
        if kind == "cache_hit":
            hits[helper] = hits.get(helper, 0) + 1
        else:
            misses[helper] = misses.get(helper, 0) + 1

all_helpers = sorted(set(list(hits) + list(misses)))
rows = []
for helper in all_helpers:
    h = hits.get(helper, 0)
    m = misses.get(helper, 0)
    total = h + m
    rate = (h / total * 100) if total > 0 else 0.0
    rows.append({"helper": helper, "hits": h, "misses": m, "total": total, "hit_rate_pct": round(rate, 1)})

total_h = sum(r["hits"] for r in rows)
total_m = sum(r["misses"] for r in rows)
total_t = total_h + total_m
overall_rate = (total_h / total_t * 100) if total_t > 0 else 0.0

if as_json:
    print(json.dumps({
        "window_hours": window_h,
        "helpers": rows,
        "overall": {"hits": total_h, "misses": total_m, "total": total_t, "hit_rate_pct": round(overall_rate, 1)},
    }, indent=2))
else:
    if not rows:
        print(f"No cache_hit/cache_miss events in the last {window_h}h. (cache may not yet be active or events not yet emitted)")
        sys.exit(0)
    col_w = max(len(r["helper"]) for r in rows) + 2
    print(f"{'helper':<{col_w}} {'hits':>6}  {'misses':>7}  {'total':>6}  hit_rate%")
    print("-" * (col_w + 38))
    for r in rows:
        print(f"{r['helper']:<{col_w}} {r['hits']:>6}  {r['misses']:>7}  {r['total']:>6}  {r['hit_rate_pct']:>8.1f}%")
    print("-" * (col_w + 38))
    print(f"{'OVERALL':<{col_w}} {total_h:>6}  {total_m:>7}  {total_t:>6}  {overall_rate:>8.1f}%")
    print()
    print(f"(window: last {window_h}h from {ambient_path})")
PY
