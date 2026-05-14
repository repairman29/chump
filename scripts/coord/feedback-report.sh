#!/usr/bin/env bash
# scripts/coord/feedback-report.sh — CREDIBLE-063
#
# Per-domain counts of FEEDBACK events (defect / proposal / preference /
# retro) over rolling 7d window. Identifies top-3 subjects by feedback
# volume. Surfaces preference vote tallies (e.g. inbox-first-picker=+5/-1)
# so operator can see WHICH defaults agents are pushing back on.
#
# Usage:
#   feedback-report.sh             # human-readable
#   feedback-report.sh --json      # machine-readable
#   feedback-report.sh --window 14d
#
# Lightweight shell implementation. Once stable, can be wired into
# `chump kpi report --feedback` (Rust side, follow-up gap).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd -P)"
LOCK_DIR="${CHUMP_LOCK_DIR:-$REPO_ROOT/.chump-locks}"
FB="$LOCK_DIR/feedback.jsonl"

WINDOW="7d"
FORMAT="human"
while [ $# -gt 0 ]; do
    case "$1" in
        --json)    FORMAT="json"; shift ;;
        --window)  WINDOW="$2"; shift 2 ;;
        -h|--help) sed -n '2,15p' "$0" | sed 's/^# \?//'; exit 0 ;;
        *) echo "[feedback-report] unknown arg: $1" >&2; exit 2 ;;
    esac
done

[ -f "$FB" ] || { [ "$FORMAT" = "json" ] && echo '{"window":"'"$WINDOW"'","total":0,"by_kind":{},"by_domain":{},"top_subjects":[],"preference_votes":{}}' || echo "[feedback-report] no feedback.jsonl yet"; exit 0; }

python3 - "$FB" "$WINDOW" "$FORMAT" <<'PY'
import json, re, sys
from collections import Counter, defaultdict
from datetime import datetime, timezone, timedelta

fb_path, window, fmt = sys.argv[1:4]

m = re.match(r'^(\d+)([dh])$', window)
if not m:
    print(f"[feedback-report] invalid --window '{window}', use Nd or Nh", file=sys.stderr)
    sys.exit(2)
n, unit = int(m.group(1)), m.group(2)
delta = timedelta(days=n) if unit == "d" else timedelta(hours=n)
cutoff = datetime.now(timezone.utc) - delta

by_kind = Counter()
by_domain = Counter()           # gap-id prefix or "?"
by_subject = Counter()          # for top-N
pref_votes = defaultdict(lambda: {"+1": 0, "-1": 0, "0": 0})  # subject -> tally
total = 0

with open(fb_path) as f:
    for raw in f:
        raw = raw.strip()
        if not raw: continue
        try: e = json.loads(raw)
        except Exception: continue
        if e.get("event") != "FEEDBACK": continue
        ts = e.get("ts", "")
        try:
            t = datetime.fromisoformat(ts.replace("Z", "+00:00"))
        except Exception:
            continue
        if t < cutoff: continue
        total += 1
        kind = e.get("kind", "?")
        subj = e.get("subject", "?")
        by_kind[kind] += 1
        by_subject[subj] += 1
        # Domain from subject: "INFRA-1271" -> "INFRA"; "policy-name" -> "OTHER"
        dom = subj.split("-", 1)[0] if "-" in subj and subj.split("-", 1)[0].isupper() else "OTHER"
        by_domain[dom] += 1
        if kind == "preference":
            v = str(e.get("vote", "0"))
            if v not in ("+1", "-1", "0"): v = "0"
            pref_votes[subj][v] += 1

top_subjects = [
    {"subject": s, "count": c}
    for s, c in by_subject.most_common(3)
]

# Format preference tallies as compact strings
pref_summary = {
    subj: {
        "plus_one": d["+1"],
        "minus_one": d["-1"],
        "zero": d["0"],
        "net": d["+1"] - d["-1"],
    } for subj, d in pref_votes.items()
}

result = {
    "window": window,
    "total": total,
    "by_kind": dict(by_kind),
    "by_domain": dict(by_domain),
    "top_subjects": top_subjects,
    "preference_votes": pref_summary,
}

if fmt == "json":
    print(json.dumps(result, indent=2))
else:
    print(f"=== FEEDBACK report (last {window}) ===")
    print(f"total events: {total}")
    print()
    print("By kind:")
    for k, c in by_kind.most_common():
        print(f"  {k:<12} {c}")
    print()
    print("By domain (from subject prefix):")
    for d, c in by_domain.most_common():
        print(f"  {d:<12} {c}")
    print()
    print("Top 3 most-discussed subjects:")
    for t in top_subjects:
        print(f"  {t['count']:>3}× {t['subject']}")
    print()
    if pref_summary:
        print("Preference votes (subject → +1/-1/0  net):")
        for subj, d in sorted(pref_summary.items(), key=lambda kv: -kv[1]["net"]):
            print(f"  {subj:<40} +{d['plus_one']}/-{d['minus_one']}/={d['zero']}  net={d['net']:+d}")
    else:
        print("(no preference votes in window)")
PY
