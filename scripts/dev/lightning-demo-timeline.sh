#!/usr/bin/env bash
# scripts/dev/lightning-demo-timeline.sh — INFRA-1887
#
# Prints the last N merged PRs authored by the current user with their
# claim→opened→merged wall-clock breakdown. This IS the prompt-to-PR-merged
# demo capture: one command, one table, screenshot-ready evidence of
# autonomous throughput.
#
# Usage:
#   lightning-demo-timeline.sh                # last 10 merged PRs, table
#   lightning-demo-timeline.sh --limit 20     # last 20
#   lightning-demo-timeline.sh --json         # machine-readable
#
# Per-row deltas:
#   claim_ts          : timestamp the gap was claimed (from state.db, or
#                       fallback to first commit on the PR's head branch)
#   claim_to_open_min : minutes from claim to PR opened
#   open_to_merge_min : minutes from PR opened to merged (CI + auto-merge)
#   total_min         : claim→merged wall clock
#
# Summary footer reports total wall clock, median per-ship, fastest, slowest.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
STATE_DB="${CHUMP_STATE_DB:-$REPO_ROOT/.chump/state.db}"

LIMIT=10
JSON=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --limit) LIMIT="$2"; shift 2 ;;
        --json) JSON=1; shift ;;
        -h|--help)
            sed -n '2,/^$/p' "$0" | grep '^#' | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *) echo "lightning-demo-timeline: unknown flag '$1'" >&2; exit 2 ;;
    esac
done

GAP_RX='(INFRA-[0-9]+|META-[0-9]+|CREDIBLE-[0-9]+|DOC-[0-9]+|FLEET-[0-9]+|RESILIENT-[0-9]+|EFFECTIVE-[0-9]+|MISSION-[0-9]+|ZERO-WASTE-[0-9]+)'

# Pull the merge data via gh — cache-friendly. Network-free fallback for
# tests is honored via stub on PATH (test-lightning-demo-timeline.sh).
RAW_PRS=$(gh pr list --author @me --state merged --limit "$LIMIT" \
    --json number,title,createdAt,mergedAt,headRefName 2>/dev/null || echo "[]")

# Per-PR resolution: gap_id + claim_ts.
# claim_ts source: state.db chump_active_leases for the gap (if present),
# else first-commit author-date on the PR's head branch.
PER_ROW=$(REPO_ROOT="$REPO_ROOT" STATE_DB="$STATE_DB" GAP_RX="$GAP_RX" RAW_PRS="$RAW_PRS" python3 <<'PYEOF'
import json
import os
import re
import subprocess
import sqlite3
from datetime import datetime, timezone

raw = os.environ.get("RAW_PRS", "[]")
state_db = os.environ.get("STATE_DB", "")
repo_root = os.environ.get("REPO_ROOT", ".")
gap_rx = re.compile(os.environ["GAP_RX"])

prs = json.loads(raw or "[]")

def parse_ts(s):
    if not s:
        return None
    try:
        return datetime.fromisoformat(s.replace("Z", "+00:00"))
    except Exception:
        return None

def first_commit_ts(branch):
    """First-commit ISO timestamp on a branch, or None."""
    if not branch:
        return None
    # Try local branch first; fall back to origin/<branch>.
    for ref in (branch, f"origin/{branch}"):
        try:
            out = subprocess.run(
                ["git", "log", "--reverse", "--format=%aI", ref, "-1"],
                capture_output=True, text=True, cwd=repo_root, timeout=10,
            )
            if out.returncode == 0 and out.stdout.strip():
                return out.stdout.strip().splitlines()[0]
        except Exception:
            continue
    return None

# state.db schema: chump_active_leases has columns including session_id,
# claimed_at (ISO ts). gaps table has lease_session_id. Inner-join via session.
db_lookup = {}
if state_db and os.path.isfile(state_db):
    try:
        con = sqlite3.connect(state_db)
        con.row_factory = sqlite3.Row
        try:
            rows = con.execute(
                "SELECT gap_id, MIN(claimed_at) AS claim_ts FROM chump_active_leases GROUP BY gap_id"
            ).fetchall()
            for r in rows:
                db_lookup[r["gap_id"]] = r["claim_ts"]
        except Exception:
            pass
        con.close()
    except Exception:
        pass

records = []
for p in prs:
    title = p.get("title", "")
    m = gap_rx.search(title)
    gap_id = m.group(1) if m else "(none)"
    created = parse_ts(p.get("createdAt", ""))
    merged = parse_ts(p.get("mergedAt", ""))
    claim_iso = db_lookup.get(gap_id) or first_commit_ts(p.get("headRefName", ""))
    claim_ts = parse_ts(claim_iso) if claim_iso else None

    def minutes_between(a, b):
        if a is None or b is None:
            return None
        return round((b - a).total_seconds() / 60.0, 1)

    records.append({
        "gap_id": gap_id,
        "pr": p.get("number"),
        "title": title[:60],
        "claim_ts": claim_iso or "?",
        "created_at": p.get("createdAt", "?"),
        "merged_at": p.get("mergedAt", "?"),
        "claim_to_open_min": minutes_between(claim_ts, created),
        "open_to_merge_min": minutes_between(created, merged),
        "total_min": minutes_between(claim_ts, merged),
    })

# Summary stats
totals = [r["total_min"] for r in records if r["total_min"] is not None]
totals.sort()
def pct(p, xs):
    if not xs: return None
    i = max(0, min(len(xs)-1, int(round(p/100*(len(xs)-1)))))
    return xs[i]
summary = {
    "ship_count": len(records),
    "total_wallclock_min": round(sum(totals), 1) if totals else 0.0,
    "median_min": pct(50, totals),
    "p10_min": pct(10, totals),
    "p90_min": pct(90, totals),
}

print(json.dumps({"records": records, "summary": summary}))
PYEOF
)

if [[ "$JSON" -eq 1 ]]; then
    echo "$PER_ROW"
    exit 0
fi

# Render as table.
echo "$PER_ROW" | python3 -c "
import json, sys
d = json.load(sys.stdin)
rows = d['records']
s = d['summary']

hdr_fmt = '{:<12} {:>5} {:>10} {:>10} {:>10}  {}'
print(hdr_fmt.format('gap_id', 'PR', 'claim→open', 'open→merge', 'total_min', 'title'))
print('-' * 100)
def fmt(v): return ('?' if v is None else f'{v:.1f}')
for r in rows:
    print(hdr_fmt.format(
        r['gap_id'][:12], '#'+str(r['pr']),
        fmt(r['claim_to_open_min']), fmt(r['open_to_merge_min']), fmt(r['total_min']),
        r['title'],
    ))
print()
print(f\"Summary: {s['ship_count']} ships, total {s['total_wallclock_min']} min, median {s['median_min']} min, p10 {s['p10_min']}, p90 {s['p90_min']}\")
print(\"        (lower = faster; the 'lightning prompt-to-PR-merged' demo)\")
"
