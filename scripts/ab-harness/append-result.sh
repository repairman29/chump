#!/usr/bin/env bash
# Append an A/B summary to docs/CONSCIOUSNESS_AB_RESULTS.md.
#
# Usage:
#   scripts/ab-harness/append-result.sh <summary.json> <gap-id> [--note "..."]
#
# The summary JSON is what score.py produces. Gap-id is the registry id
# (e.g. COG-011) that the run corresponds to — used in the heading and
# searchable in the appended block.

set -euo pipefail

if [[ $# -lt 2 ]]; then
  sed -n '2,12p' "$0"
  exit 2
fi

SUMMARY="$1"
GAP_ID="$2"
shift 2

NOTE=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --note) NOTE="$2"; shift 2;;
    *) echo "unknown arg: $1" >&2; exit 2;;
  esac
done

if [[ ! -f "$SUMMARY" ]]; then
  echo "ERROR: summary not found: $SUMMARY" >&2
  exit 2
fi

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
RESULTS="$ROOT/docs/CONSCIOUSNESS_AB_RESULTS.md"
if [[ ! -f "$RESULTS" ]]; then
  echo "ERROR: $RESULTS not found" >&2
  exit 2
fi

DATE_ISO=$(date -u +%Y-%m-%dT%H:%M:%SZ)
MODEL="${OPENAI_MODEL:-unknown}"
ENDPOINT="${OPENAI_API_BASE:-unknown}"

python3.12 - "$SUMMARY" "$GAP_ID" "$DATE_ISO" "$MODEL" "$ENDPOINT" "$NOTE" <<'PY' >>"$RESULTS"
import json, sys
summary_path, gap_id, date_iso, model, endpoint, note = sys.argv[1:]
s = json.loads(open(summary_path).read())

print()
print(f"## {gap_id} — {s['tag']} ({date_iso})")
print()
print(f"- model: `{model}` @ `{endpoint}`")
print(f"- trials: {s['trial_count']} across {s['task_count']} tasks, 2 modes (A=flag:1, B=flag:0)")
if note:
    print(f"- note: {note}")
print()
print("| mode | passed | failed | rate |")
print("|------|-------:|-------:|------|")
for mode in ("A", "B"):
    m = s['by_mode'].get(mode, {})
    if m:
        print(f"| {mode}    | {m['passed']:>6} | {m['failed']:>6} | {m['rate']:.3f} |")
print()
print(f"**Delta (A − B): {s['delta']:+.3f}**")
print()
if s.get('by_category'):
    print("| category | A rate | B rate | Δ |")
    print("|----------|-------:|-------:|--:|")
    for cat, m in s['by_category'].items():
        a = m.get('A', {}).get('rate', 0.0)
        b = m.get('B', {}).get('rate', 0.0)
        d = s['delta_by_category'].get(cat, 0.0)
        print(f"| {cat} | {a:.3f} | {b:.3f} | {d:+.3f} |")
print()
PY

echo "[append-result] appended ${GAP_ID} block to $RESULTS"
