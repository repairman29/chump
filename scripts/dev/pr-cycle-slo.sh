#!/usr/bin/env bash
# scripts/dev/pr-cycle-slo.sh — INFRA-1417
#
# Per-PR wall-clock SLO: pages over merged PRs from the github cache
# (.chump/github_cache.db, cache-first per INFRA-1081) in the last N days,
# computes median + p90 of (created_at -> merged_at) in minutes, and emits
# kind=pr_cycle_slo to ambient.jsonl. When p90 > 120min it also emits a
# separate kind=pr_cycle_slo_breach alert.
#
# Usage:
#   scripts/dev/pr-cycle-slo.sh                  # last 7 days, emits ambient
#   scripts/dev/pr-cycle-slo.sh --window-days 3
#   scripts/dev/pr-cycle-slo.sh --json            # print JSON to stdout too
#   scripts/dev/pr-cycle-slo.sh --no-emit         # compute only, don't write ambient
#
# Data source: pr_state.raw_payload_json (webhook/REST payload) carries
# created_at; pr_state.merged_at is a first-class column. Falls back to
# `gh pr list --state merged` only if the cache DB is entirely absent
# (cache-first per CLAUDE.md).

set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
DB="${CHUMP_CACHE_DB:-$REPO_ROOT/.chump/github_cache.db}"
AMBIENT="${CHUMP_AMBIENT_OVERRIDE:-$REPO_ROOT/.chump-locks/ambient.jsonl}"
WINDOW_DAYS=7
AS_JSON=0
EMIT=1
BREACH_THRESHOLD_MIN=120

while [[ $# -gt 0 ]]; do
    case "$1" in
        --window-days) WINDOW_DAYS="$2"; shift 2 ;;
        --json)        AS_JSON=1; shift ;;
        --no-emit)     EMIT=0; shift ;;
        --threshold-min) BREACH_THRESHOLD_MIN="$2"; shift 2 ;;
        -h|--help)
            sed -n '1,/^$/p' "$0" | sed 's/^# \{0,1\}//'
            exit 0 ;;
        *) echo "unknown arg: $1" >&2; exit 2 ;;
    esac
done

if [[ ! -f "$DB" ]]; then
    echo "no github_cache.db at $DB — nothing to compute" >&2
    exit 0
fi

python3 - "$DB" "$AMBIENT" "$WINDOW_DAYS" "$AS_JSON" "$EMIT" "$BREACH_THRESHOLD_MIN" <<'PY'
import json
import sqlite3
import statistics
import sys
from datetime import datetime, timedelta, timezone

db_path, ambient_path, window_days, as_json, emit, threshold_min = sys.argv[1:7]
window_days = int(window_days)
as_json = as_json == "1"
emit = emit == "1"
threshold_min = float(threshold_min)

cutoff = datetime.now(timezone.utc) - timedelta(days=window_days)

conn = sqlite3.connect(db_path)
conn.row_factory = sqlite3.Row
rows = conn.execute(
    "SELECT number, merged_at, raw_payload_json FROM pr_state "
    "WHERE merged_at IS NOT NULL AND merged_at != ''"
).fetchall()

deltas_min = []
for row in rows:
    merged_at_raw = row["merged_at"]
    try:
        merged_at = datetime.fromisoformat(merged_at_raw.replace("Z", "+00:00"))
    except (ValueError, AttributeError):
        continue
    if merged_at.tzinfo is None:
        merged_at = merged_at.replace(tzinfo=timezone.utc)
    if merged_at < cutoff:
        continue

    created_at_raw = None
    payload_raw = row["raw_payload_json"]
    if payload_raw:
        try:
            payload = json.loads(payload_raw)
        except (json.JSONDecodeError, TypeError):
            payload = {}
        pr = payload.get("pull_request", payload) if isinstance(payload, dict) else {}
        created_at_raw = (pr or {}).get("created_at") or payload.get("created_at") if isinstance(payload, dict) else None
    if not created_at_raw:
        continue
    try:
        created_at = datetime.fromisoformat(created_at_raw.replace("Z", "+00:00"))
    except ValueError:
        continue
    if created_at.tzinfo is None:
        created_at = created_at.replace(tzinfo=timezone.utc)

    delta_min = (merged_at - created_at).total_seconds() / 60.0
    if delta_min < 0:
        continue
    deltas_min.append(delta_min)

sample_size = len(deltas_min)
if sample_size == 0:
    median_min = None
    p90_min = None
else:
    deltas_sorted = sorted(deltas_min)
    median_min = statistics.median(deltas_sorted)
    # nearest-rank p90 — simple, deterministic, no numpy dependency.
    idx = max(0, min(sample_size - 1, int(round(0.9 * (sample_size - 1)))))
    p90_min = deltas_sorted[idx]

ts = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
result = {
    "ts": ts,
    "kind": "pr_cycle_slo",
    "window_days": window_days,
    "median_min": round(median_min, 1) if median_min is not None else None,
    "p90_min": round(p90_min, 1) if p90_min is not None else None,
    "sample_size": sample_size,
}

if as_json:
    print(json.dumps(result))
else:
    if sample_size == 0:
        print(f"pr-cycle-slo: no merged PRs in last {window_days}d — p90=inf (no data)")
    else:
        print(
            f"pr-cycle-slo: window={window_days}d n={sample_size} "
            f"median={result['median_min']}min p90={result['p90_min']}min"
        )

breach = sample_size > 0 and p90_min is not None and p90_min > threshold_min
if breach:
    breach_msg = (
        f"pr-cycle-slo BREACH: p90={result['p90_min']}min > {threshold_min}min "
        f"threshold (window={window_days}d, n={sample_size})"
    )
    print(breach_msg, file=sys.stderr)

if emit:
    with open(ambient_path, "a") as f:
        f.write(json.dumps(result) + "\n")
        if breach:
            breach_event = {
                "ts": ts,
                "kind": "pr_cycle_slo_breach",
                "window_days": window_days,
                "p90_min": result["p90_min"],
                "threshold_min": threshold_min,
                "sample_size": sample_size,
            }
            f.write(json.dumps(breach_event) + "\n")

sys.exit(0)
PY
