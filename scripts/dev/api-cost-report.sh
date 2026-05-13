#!/usr/bin/env bash
# scripts/dev/api-cost-report.sh — INFRA-999
#
# Tail .chump-locks/ambient.jsonl for github_api_call events in the last
# WINDOW_HOURS (default 24) and print a ranked report grouped by
# (script, api). Output is plain text by default; pass --json for a
# machine-readable summary.
#
# Usage:
#   scripts/dev/api-cost-report.sh                   # last 24h
#   scripts/dev/api-cost-report.sh --window 2h       # last 2h
#   scripts/dev/api-cost-report.sh --json            # JSON to stdout

set -euo pipefail

WINDOW="24h"
AS_JSON=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --window) WINDOW="$2"; shift 2 ;;
        --json)   AS_JSON=1; shift ;;
        -h|--help)
            sed -n '1,/^$/p' "$0" | sed 's/^# \{0,1\}//'
            exit 0 ;;
        *) echo "unknown arg: $1" >&2; exit 2 ;;
    esac
done

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
AMBIENT="${CHUMP_AMBIENT_OVERRIDE:-${REPO_ROOT}/.chump-locks/ambient.jsonl}"
[[ -f "$AMBIENT" ]] || { echo "no ambient.jsonl at $AMBIENT" >&2; exit 0; }

python3 - "$AMBIENT" "$WINDOW" "$AS_JSON" <<'PY'
import json
import re
import sys
from collections import Counter
from datetime import datetime, timedelta, timezone

path, window, as_json = sys.argv[1], sys.argv[2], sys.argv[3] == "1"

m = re.fullmatch(r"(\d+)([hd])", window)
if not m:
    print(f"invalid --window {window!r} (use NNh or NNd)", file=sys.stderr)
    sys.exit(2)
n, unit = int(m.group(1)), m.group(2)
delta = timedelta(hours=n) if unit == "h" else timedelta(days=n)
cutoff = datetime.now(timezone.utc) - delta

counts: Counter = Counter()
total = 0
min_core = None
min_gql = None
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
        total += 1
        key = (ev.get("script") or "?", ev.get("api") or "?")
        counts[key] += 1
        rc = ev.get("remaining_core")
        rg = ev.get("remaining_graphql")
        if isinstance(rc, int) and rc >= 0 and (min_core is None or rc < min_core):
            min_core = rc
        if isinstance(rg, int) and rg >= 0 and (min_gql is None or rg < min_gql):
            min_gql = rg

if as_json:
    print(json.dumps({
        "window": window,
        "total_calls": total,
        "min_remaining_core": min_core,
        "min_remaining_graphql": min_gql,
        "by_script_api": [
            {"script": s, "api": a, "calls": c}
            for (s, a), c in counts.most_common()
        ],
    }, indent=2))
    sys.exit(0)

print(f"=== GitHub API cost — last {window} ===")
print(f"total calls: {total}")
if min_core is not None or min_gql is not None:
    parts = []
    if min_core is not None: parts.append(f"core min={min_core}")
    if min_gql is not None: parts.append(f"graphql min={min_gql}")
    print(f"floor seen: {'  '.join(parts)}")
print()
if not counts:
    print("(no github_api_call events in window)")
    sys.exit(0)
width_s = max(len(s) for s, _ in counts) + 2
width_a = max(len(a) for _, a in counts) + 2
for (script, api), c in counts.most_common():
    print(f"{script:<{width_s}}{api:<{width_a}}{c:>5} calls")
PY
