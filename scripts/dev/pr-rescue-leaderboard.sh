#!/usr/bin/env bash
# META-254 (META-247 slice d): pr-rescue-leaderboard.sh — recurring-fingerprint audit.
#
# Reads .chump-locks/ambient.jsonl for `pr_action_taken` events, extracts each
# event's `sha256` failure fingerprint + timestamp, groups by fingerprint+day,
# and prints the top-5 most recurring fingerprints. Exits non-zero if any
# single fingerprint appears 3+ times within a rolling 24h window — that is
# the "same rescue-class surface recurring" doctrine violation META-247 exists
# to catch (see docs/gaps/META-247.yaml).
#
# Usage:
#   scripts/dev/pr-rescue-leaderboard.sh                  # last 7 days, table
#   scripts/dev/pr-rescue-leaderboard.sh --days 14         # custom window
#   scripts/dev/pr-rescue-leaderboard.sh --json            # machine-readable
#   scripts/dev/pr-rescue-leaderboard.sh --ambient FILE     # override ambient log path

set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
AMBIENT="${CHUMP_AMBIENT_LOG:-$REPO_ROOT/.chump-locks/ambient.jsonl}"
DAYS=7
JSON=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --days) DAYS="$2"; shift 2 ;;
        --json) JSON=1; shift ;;
        --ambient) AMBIENT="$2"; shift 2 ;;
        --help|-h)
            cat <<'USAGE'
pr-rescue-leaderboard.sh — META-247 recurring-fingerprint audit

Aggregates ambient `pr_action_taken` events by their `sha256` fingerprint
field, bucketed by day, and prints the top-5 most recurring fingerprints.

Options:
  --days N       window in days (default 7)
  --json         emit a JSON summary instead of a text table
  --ambient FILE override the ambient.jsonl path (default: .chump-locks/ambient.jsonl)
  --help         this message

Exit 0 if no fingerprint appears 3+ times in any rolling 24h window,
1 otherwise.
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

python3 - "$AMBIENT" "$DAYS" "$JSON" <<'PYEOF'
import json
import sys
from collections import defaultdict
from datetime import datetime, timedelta, timezone

ambient_path, days_str, json_flag = sys.argv[1:]
days = int(days_str)
emit_json = json_flag == "1"

cutoff = datetime.now(timezone.utc) - timedelta(days=days)


def parse_ts(ts):
    try:
        if ts.endswith("Z"):
            dt = datetime.fromisoformat(ts.replace("Z", "+00:00"))
        else:
            dt = datetime.fromisoformat(ts)
            if dt.tzinfo is None:
                dt = dt.replace(tzinfo=timezone.utc)
        return dt
    except (ValueError, AttributeError):
        return None


# fingerprint -> list of datetimes (for rolling-24h-window breach check)
events_by_fp = defaultdict(list)
# (fingerprint, day) -> count
by_fp_day = defaultdict(int)

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
            if rec.get("kind") != "pr_action_taken":
                continue
            fp = rec.get("sha256")
            if not fp:
                continue
            dt = parse_ts(rec.get("ts", ""))
            if dt is None or dt < cutoff:
                continue
            events_by_fp[fp].append(dt)
            by_fp_day[(fp, dt.date().isoformat())] += 1
except FileNotFoundError:
    print(f"ambient log not found: {ambient_path}", file=sys.stderr)
    sys.exit(0)

# Rolling-24h breach check: for each fingerprint, sort its timestamps and
# see if any 3 consecutive occurrences fall within a 24h span.
breached_fps = set()
for fp, timestamps in events_by_fp.items():
    ts_sorted = sorted(timestamps)
    for i in range(len(ts_sorted) - 2):
        if ts_sorted[i + 2] - ts_sorted[i] <= timedelta(hours=24):
            breached_fps.add(fp)
            break

# Top-5 most recurring fingerprints overall (by total occurrence count).
totals = defaultdict(int)
for (fp, _day), count in by_fp_day.items():
    totals[fp] += count

top5 = sorted(totals.items(), key=lambda kv: kv[1], reverse=True)[:5]

if emit_json:
    out = {
        "window_days": days,
        "top5": [
            {"sha256": fp, "total_occurrences": count, "breached_24h": fp in breached_fps}
            for fp, count in top5
        ],
        "breached_fingerprints": sorted(breached_fps),
    }
    print(json.dumps(out))
else:
    print(f"pr-rescue-leaderboard: top-5 recurring fingerprints (last {days}d)")
    print(f"{'sha256':<16}  {'total':>6}  {'breach_24h':>10}")
    print("-" * 40)
    if not top5:
        print("(no pr_action_taken events with sha256 fingerprint in window)")
    for fp, count in top5:
        short_fp = fp[:12] if len(fp) > 12 else fp
        breach_flag = "YES" if fp in breached_fps else ""
        print(f"{short_fp:<16}  {count:>6}  {breach_flag:>10}")

if breached_fps:
    if not emit_json:
        print(
            f"\nALERT: {len(breached_fps)} fingerprint(s) recurred 3+ times within 24h",
            file=sys.stderr,
        )
    sys.exit(1)
sys.exit(0)
PYEOF
