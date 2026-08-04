#!/usr/bin/env bash
# review-verdict-report.sh — CREDIBLE-191 (judgment panel: learning-loop consumer)
#
# Reads the review_verdict ambient events emitted by code-reviewer-agent.sh
# (CREDIBLE-191 slice-3) and reports which lens actually catches what — the
# calibration signal the judgment panel needs. This CONSUMES the events slice-3
# emits, closing the emit->consume loop: without a reader the emit is telemetry
# into the void; with it, the fleet can see whether SPIRIT/CORRECTNESS/HARMONY
# are each earning their place (and which is doing the blocking work).
#
# Usage:
#   review-verdict-report.sh [--json] [--since <ISO8601>] [--ambient <path>]
#     --json           machine-readable output (for a future calibration step)
#     --since <ISO>    only events with ts >= this (lexical ISO-8601 compare)
#     --ambient <path> override the ambient log (default: repo .chump-locks/ambient.jsonl)
set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || echo .)"
AMBIENT="${CHUMP_AMBIENT_LOG:-$REPO_ROOT/.chump-locks/ambient.jsonl}"
JSON=0
SINCE=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --json)    JSON=1 ;;
    --since)   SINCE="${2:-}"; shift ;;
    --ambient) AMBIENT="${2:-}"; shift ;;
    -h|--help) grep -E '^#( |$)' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
  shift
done

if [[ ! -f "$AMBIENT" ]]; then
  echo "review-verdict-report: no ambient log at $AMBIENT" >&2
  exit 0
fi

python3 - "$AMBIENT" "$JSON" "$SINCE" <<'PY'
import sys, json
path, as_json, since = sys.argv[1], sys.argv[2] == "1", sys.argv[3]
rows = []
with open(path, encoding="utf-8", errors="replace") as fh:
    for line in fh:
        if '"kind":"review_verdict"' not in line:
            continue
        try:
            d = json.loads(line)
        except Exception:
            continue
        if d.get("kind") != "review_verdict":
            continue
        if since and str(d.get("ts", "")) < since:
            continue
        rows.append(d)

def dist(key):
    c = {}
    for r in rows:
        v = r.get(key) or "(none)"
        c[v] = c.get(v, 0) + 1
    return dict(sorted(c.items(), key=lambda kv: -kv[1]))

blocking = [r for r in rows if r.get("verdict") in ("CONCERN", "ESCALATE")]
# Among blocking verdicts, how often each lens returned its blocking value —
# the "which lens is doing the work" calibration signal.
lens_catches = {
    "spirit=STUB":            sum(1 for r in blocking if r.get("spirit") == "STUB"),
    "correctness=FALSE-GREEN": sum(1 for r in blocking if r.get("correctness") == "FALSE-GREEN"),
    "harmony=REGRESSION-RISK": sum(1 for r in blocking if r.get("harmony") == "REGRESSION-RISK"),
}
out = {
    "total": len(rows),
    "verdicts": dist("verdict"),
    "spirit": dist("spirit"),
    "correctness": dist("correctness"),
    "harmony": dist("harmony"),
    "blocking_verdicts": len(blocking),
    "lens_catches": lens_catches,
}

if as_json:
    print(json.dumps(out, indent=2))
    sys.exit(0)

print(f"review_verdict report — {out['total']} reviews")
print(f"  verdicts:    {out['verdicts']}")
print(f"  spirit:      {out['spirit']}")
print(f"  correctness: {out['correctness']}")
print(f"  harmony:     {out['harmony']}")
print(f"  blocking:    {out['blocking_verdicts']}   lens-catches: {lens_catches}")
PY
