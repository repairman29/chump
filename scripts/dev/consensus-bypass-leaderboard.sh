#!/usr/bin/env bash
# INFRA-2274 (d): consensus-bypass-leaderboard.sh — daily bypass-ratio audit.
#
# Reads .chump-locks/ambient.jsonl for INFRA-2274 consensus-gate events and
# prints {date, total_merges, consensus_approved, operator_bypass, would_block,
# bypass_ratio} per day for ops visibility.
#
# Operator value: when today's "105 admin-merged" becomes
# "N consensus-approved + M operator-bypass-with-reason", this dashboard makes
# the M visible (and the bypass_ratio enforceable as an SLO threshold).
#
# Usage:
#   scripts/dev/consensus-bypass-leaderboard.sh                  # last 7 days
#   scripts/dev/consensus-bypass-leaderboard.sh --days 14        # custom window
#   scripts/dev/consensus-bypass-leaderboard.sh --json           # machine-readable
#   scripts/dev/consensus-bypass-leaderboard.sh --threshold 0.10 # exit 1 if any day > 10%

set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
AMBIENT="${CHUMP_AMBIENT_LOG:-$REPO_ROOT/.chump-locks/ambient.jsonl}"
DAYS=7
JSON=0
THRESHOLD=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --days) DAYS="$2"; shift 2 ;;
        --json) JSON=1; shift ;;
        --threshold) THRESHOLD="$2"; shift 2 ;;
        --help|-h)
            cat <<'USAGE'
consensus-bypass-leaderboard.sh — INFRA-2274 daily bypass-ratio audit

Aggregates these ambient event kinds per day:
  - consensus_gate_approved   (gate ran, verdict=PASSED)
  - consensus_gate_blocked    (gate ran, verdict!=PASSED, mode=enforce)
  - consensus_gate_would_block (gate ran, verdict!=PASSED, mode=shadow)
  - consensus_bypass_used     (operator escape hatch invoked)

Options:
  --days N           window in days (default 7)
  --json             emit JSON Lines instead of tabular text
  --threshold X      exit 1 if bypass_ratio > X on any day (e.g. 0.10)
  --help             this message

Exit 0 if no threshold breach, 1 otherwise.
USAGE
            exit 0
            ;;
        *) echo "unknown arg: $1" >&2; exit 2 ;;
    esac
done

if [[ ! -f "$AMBIENT" ]]; then
    echo "ambient log not found: $AMBIENT" >&2
    exit 0
fi

# Per-day aggregation via python3. Lines of interest are JSON dicts with
# "ts" + "kind" matching one of the four consensus-gate kinds.
python3 - "$AMBIENT" "$DAYS" "$JSON" "${THRESHOLD:-}" <<'PYEOF'
import json
import sys
from collections import defaultdict
from datetime import datetime, timedelta, timezone

ambient_path, days_str, json_flag, threshold_str = sys.argv[1:]
days = int(days_str)
emit_json = json_flag == "1"
threshold = float(threshold_str) if threshold_str else None

kinds_of_interest = {
    "consensus_gate_approved",
    "consensus_gate_blocked",
    "consensus_gate_would_block",
    "consensus_bypass_used",
}

# date -> {approved, blocked, would_block, bypass}
buckets = defaultdict(lambda: {"approved": 0, "blocked": 0, "would_block": 0, "bypass": 0})

cutoff = datetime.now(timezone.utc) - timedelta(days=days)

try:
    with open(ambient_path, "r", encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                rec = json.loads(line)
            except (json.JSONDecodeError, ValueError):
                continue
            kind = rec.get("kind", "")
            if kind not in kinds_of_interest:
                continue
            ts = rec.get("ts", "")
            try:
                # tolerate Z suffix and timezone offsets
                if ts.endswith("Z"):
                    dt = datetime.fromisoformat(ts.replace("Z", "+00:00"))
                else:
                    dt = datetime.fromisoformat(ts)
                    if dt.tzinfo is None:
                        dt = dt.replace(tzinfo=timezone.utc)
            except ValueError:
                continue
            if dt < cutoff:
                continue
            day = dt.date().isoformat()
            if kind == "consensus_gate_approved":
                buckets[day]["approved"] += 1
            elif kind == "consensus_gate_blocked":
                buckets[day]["blocked"] += 1
            elif kind == "consensus_gate_would_block":
                buckets[day]["would_block"] += 1
            elif kind == "consensus_bypass_used":
                buckets[day]["bypass"] += 1
except FileNotFoundError:
    print(f"ambient log not found: {ambient_path}", file=sys.stderr)
    sys.exit(0)

# Sort by date ascending.
breached = False
days_sorted = sorted(buckets.keys())

if not emit_json:
    print(f"{'date':<12}  {'total':>6}  {'approved':>9}  {'bypass':>7}  {'would_blk':>10}  {'blocked':>8}  {'ratio':>6}")
    print("-" * 72)

for day in days_sorted:
    b = buckets[day]
    total = b["approved"] + b["bypass"] + b["would_block"] + b["blocked"]
    if total == 0:
        ratio = 0.0
    else:
        ratio = b["bypass"] / total
    if threshold is not None and ratio > threshold:
        breached = True
    if emit_json:
        print(json.dumps({
            "date": day,
            "total_merges": total,
            "consensus_approved": b["approved"],
            "operator_bypass": b["bypass"],
            "shadow_would_block": b["would_block"],
            "enforced_blocked": b["blocked"],
            "bypass_ratio": round(ratio, 4),
        }))
    else:
        print(f"{day:<12}  {total:>6}  {b['approved']:>9}  {b['bypass']:>7}  {b['would_block']:>10}  {b['blocked']:>8}  {ratio:>5.1%}")

if not emit_json and not days_sorted:
    print("(no consensus-gate events in window)")

if threshold is not None and breached:
    print(f"\nALERT: bypass_ratio > {threshold:.1%} on at least one day", file=sys.stderr)
    sys.exit(1)
sys.exit(0)
PYEOF
