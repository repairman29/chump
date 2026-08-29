#!/usr/bin/env bash
# scripts/dev/pr-cycle-slo.sh — INFRA-1417
#
# Fleet-wide "PR opened → merged" wall-clock SLO. Pages the local
# .chump/github_cache.db (INFRA-1081) for closed/merged PRs in the last
# N days, computes median + p90 of (merged_at - created_at) in minutes,
# and emits kind=pr_cycle_slo to ambient.jsonl. If p90 exceeds the
# breach threshold, also emits kind=pr_cycle_slo_breach.
#
# created_at isn't a first-class pr_state column — it's pulled from the
# raw_payload_json blob (the full PR JSON GitHub sends), same approach
# _bounced_pr_classifier.py uses for other PR-shape fields.
#
# Usage:
#   scripts/dev/pr-cycle-slo.sh                    # last 7 days, human output
#   scripts/dev/pr-cycle-slo.sh --window-days 14
#   scripts/dev/pr-cycle-slo.sh --json
#   scripts/dev/pr-cycle-slo.sh --breach-threshold-min 90
#
# Env:
#   CHUMP_CACHE_DB    — override .chump/github_cache.db path
#   CHUMP_AMBIENT_LOG — override .chump-locks/ambient.jsonl path

set -euo pipefail

WINDOW_DAYS=7
BREACH_THRESHOLD_MIN=120
AS_JSON=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --window-days)          WINDOW_DAYS="$2"; shift 2 ;;
        --breach-threshold-min) BREACH_THRESHOLD_MIN="$2"; shift 2 ;;
        --json)                 AS_JSON=1; shift ;;
        -h|--help)
            sed -n '1,/^$/p' "$0" | sed 's/^# \{0,1\}//'
            exit 0 ;;
        *) echo "unknown arg: $1" >&2; exit 2 ;;
    esac
done

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
CACHE_DB="${CHUMP_CACHE_DB:-$REPO_ROOT/.chump/github_cache.db}"
AMBIENT="${CHUMP_AMBIENT_LOG:-$REPO_ROOT/.chump-locks/ambient.jsonl}"

if [[ ! -f "$CACHE_DB" ]]; then
    echo "no github_cache.db at $CACHE_DB — nothing to compute" >&2
    exit 0
fi

python3 - "$CACHE_DB" "$AMBIENT" "$WINDOW_DAYS" "$BREACH_THRESHOLD_MIN" "$AS_JSON" <<'PY'
import json
import sqlite3
import statistics
import sys
from datetime import datetime, timedelta, timezone

db_path, ambient_path, window_days, breach_threshold_min, as_json = sys.argv[1:6]
window_days = int(window_days)
breach_threshold_min = float(breach_threshold_min)
as_json = as_json == "1"

now = datetime.now(timezone.utc)
cutoff = now - timedelta(days=window_days)

conn = sqlite3.connect(db_path)
conn.row_factory = sqlite3.Row
rows = conn.execute(
    """
    SELECT number, merged_at, raw_payload_json
    FROM pr_state
    WHERE merged_at IS NOT NULL AND merged_at != ''
    """
).fetchall()

def parse_ts(s):
    if not s:
        return None
    try:
        return datetime.strptime(s, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)
    except ValueError:
        return None

deltas_min = []
for row in rows:
    merged_at = parse_ts(row["merged_at"])
    if merged_at is None or merged_at < cutoff:
        continue
    created_at = None
    if row["raw_payload_json"]:
        try:
            payload = json.loads(row["raw_payload_json"])
            created_at = parse_ts(payload.get("created_at"))
        except (json.JSONDecodeError, TypeError):
            created_at = None
    if created_at is None:
        continue
    delta_min = (merged_at - created_at).total_seconds() / 60.0
    if delta_min < 0:
        continue
    deltas_min.append(delta_min)

sample_size = len(deltas_min)
if sample_size == 0:
    median_min = None
    p90_min = None
else:
    deltas_min.sort()
    median_min = statistics.median(deltas_min)
    # nearest-rank p90 — simple, deterministic, matches small-N synthetic fixtures.
    idx = min(sample_size - 1, int(round(0.9 * (sample_size - 1))))
    p90_min = deltas_min[idx]

ts = now.strftime("%Y-%m-%dT%H:%M:%SZ")
event = {
    "ts": ts,
    "kind": "pr_cycle_slo",
    "window_days": window_days,
    "median_min": round(median_min, 1) if median_min is not None else None,
    "p90_min": round(p90_min, 1) if p90_min is not None else None,
    "sample_size": sample_size,
}

breach_event = None
if p90_min is not None and p90_min > breach_threshold_min:
    breach_event = {
        "ts": ts,
        "kind": "pr_cycle_slo_breach",
        "window_days": window_days,
        "p90_min": round(p90_min, 1),
        "breach_threshold_min": breach_threshold_min,
        "sample_size": sample_size,
    }

with open(ambient_path, "a") as f:
    f.write(json.dumps(event) + "\n")
    if breach_event is not None:
        f.write(json.dumps(breach_event) + "\n")

if as_json:
    print(json.dumps({"pr_cycle_slo": event, "pr_cycle_slo_breach": breach_event}))
else:
    print(f"window_days={window_days} sample_size={sample_size} "
          f"median_min={event['median_min']} p90_min={event['p90_min']}")
    if breach_event is not None:
        print(f"BREACH: p90_min={breach_event['p90_min']} > threshold={breach_threshold_min}")
PY
