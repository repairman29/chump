#!/usr/bin/env bash
# scripts/dev/api-cost-leaderboard.sh — INFRA-1077
#
# Tails .chump-locks/ambient.jsonl for `kind=github_api_call` events over a
# window and prints a ranked report by (script, api). Uses the INFRA-999
# chump_gh telemetry — every wrapped gh invocation already logs there.
#
# Output:
#   default — human-readable table sorted by est_points desc
#   --json  — machine-readable: [{script, api, calls, p50_ms, p95_ms, est_points}, ...]
#
# Cost heuristic (est_points): the table below maps each `api` tag to a rough
# GraphQL point cost. Cheap REST calls = 1, GraphQL writes = 5. Used purely for
# RANKING, not for budget enforcement. Refine later as we get data.
#
# Usage:
#   scripts/dev/api-cost-leaderboard.sh                    # last 24h, text
#   scripts/dev/api-cost-leaderboard.sh --window 1h        # last 1h
#   scripts/dev/api-cost-leaderboard.sh --top 5            # top 5 rows
#   scripts/dev/api-cost-leaderboard.sh --json             # JSON

set -euo pipefail

WINDOW="24h"
TOP=10
AS_JSON=0
EMIT_AMBIENT=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --window) WINDOW="$2"; shift 2 ;;
        --top)    TOP="$2"; shift 2 ;;
        --json)   AS_JSON=1; shift ;;
        --emit-ambient) EMIT_AMBIENT=1; shift ;;  # used by the daily cron
        -h|--help)
            sed -n '1,/^$/p' "$0" | sed 's/^# \{0,1\}//'
            exit 0 ;;
        *) echo "unknown arg: $1" >&2; exit 2 ;;
    esac
done

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
AMBIENT="${CHUMP_AMBIENT_OVERRIDE:-$REPO_ROOT/.chump-locks/ambient.jsonl}"
[[ -f "$AMBIENT" ]] || { echo "no ambient.jsonl at $AMBIENT" >&2; exit 0; }

python3 - "$AMBIENT" "$WINDOW" "$TOP" "$AS_JSON" "$EMIT_AMBIENT" "$REPO_ROOT" <<'PY'
import json
import re
import statistics
import sys
from collections import defaultdict
from datetime import datetime, timedelta, timezone

path, window, top, as_json, emit_ambient, repo_root = sys.argv[1:7]
top = int(top)
as_json = as_json == "1"
emit_ambient = emit_ambient == "1"

m = re.fullmatch(r"(\d+)([hd])", window)
if not m:
    print(f"invalid --window {window!r} (use NNh or NNd)", file=sys.stderr)
    sys.exit(2)
n, unit = int(m.group(1)), m.group(2)
delta = timedelta(hours=n) if unit == "h" else timedelta(days=n)
cutoff = datetime.now(timezone.utc) - delta

# Cost heuristic — rough GraphQL points per api tag. Used for ranking only.
# REST calls don't burn GraphQL; we still rank by call count + duration.
COST = {
    "pr merge": 5, "pr create": 5, "pr edit": 2, "pr close": 2,
    "pr view": 1, "pr list": 1, "pr diff": 1, "pr comment": 1,
    "pr update-branch": 5,
    "api": 1, "run watch": 1, "run rerun": 1, "run view": 1,
    "repo view": 1,
}
def estimate(api: str) -> int:
    return COST.get(api, 2)  # default 2 points for unknown api tags

buckets = defaultdict(list)  # (script, api) -> [used_ms,...]
total = 0
with open(path) as f:
    for line in f:
        line = line.strip()
        if not line:
            continue
        try:
            ev = json.loads(line)
        except Exception:
            continue
        if ev.get("kind") != "github_api_call":
            continue
        ts = ev.get("ts", "")
        try:
            dt = datetime.strptime(ts, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)
        except Exception:
            continue
        if dt < cutoff:
            continue
        key = (ev.get("script") or "?", ev.get("api") or "?")
        used = ev.get("used_ms")
        if isinstance(used, (int, float)):
            buckets[key].append(int(used))
        else:
            buckets[key].append(0)
        total += 1

rows = []
for (script, api), times in buckets.items():
    calls = len(times)
    times_sorted = sorted(times)
    p50 = times_sorted[len(times_sorted) // 2] if times_sorted else 0
    p95_idx = int(len(times_sorted) * 0.95)
    p95 = times_sorted[min(p95_idx, len(times_sorted) - 1)] if times_sorted else 0
    est_points = calls * estimate(api)
    rows.append({
        "script": script, "api": api, "calls": calls,
        "p50_ms": p50, "p95_ms": p95, "est_points": est_points,
    })
rows.sort(key=lambda r: (-r["est_points"], -r["calls"]))
rows = rows[:top]

if as_json:
    print(json.dumps({
        "window": window, "total_calls": total, "top_n": top, "rows": rows,
    }, indent=2))
    sys.exit(0)

print(f"=== GitHub API leaderboard — last {window}, top {top} ===")
print(f"total kind=github_api_call events: {total}")
print()
if not rows:
    print("(no events in window)")
    sys.exit(0)
w_s = max(len(r["script"]) for r in rows) + 2
w_a = max(len(r["api"]) for r in rows) + 2
print(f"{'SCRIPT':<{w_s}}{'API':<{w_a}}{'CALLS':>7}{'P50ms':>8}{'P95ms':>8}{'POINTS':>9}")
for r in rows:
    print(f"{r['script']:<{w_s}}{r['api']:<{w_a}}{r['calls']:>7}{r['p50_ms']:>8}{r['p95_ms']:>8}{r['est_points']:>9}")

# INFRA-1077: daily cron emits a digest event so fleet-brief can show "this
# week's top burner" without re-reading ambient.jsonl every time.
if emit_ambient and rows:
    top_row = rows[0]
    ev = {
        "ts": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "kind": "api_cost_digest_emitted",
        "window_hours": int(delta.total_seconds() // 3600),
        "total_calls": total,
        "top_script": top_row["script"],
        "top_api": top_row["api"],
        "total_estimated_points": sum(r["est_points"] for r in rows),
    }
    amb = f"{repo_root}/.chump-locks/ambient.jsonl"
    try:
        with open(amb, "a") as f:
            f.write(json.dumps(ev, separators=(",", ":")) + "\n")
        print(f"\n(emitted kind=api_cost_digest_emitted to {amb})")
    except Exception as e:
        print(f"\n(could not emit ambient: {e})", file=sys.stderr)
PY
