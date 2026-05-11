#!/usr/bin/env bash
# model-ship-rate.sh — CREDIBLE-025: per-model ship-rate breakdown from ambient.jsonl.
#
# Reads ship_grade events emitted by bot-merge.sh and groups by model.
# Shows: model | gaps_graded | clippy_ok% | test_added%
#
# Usage:
#   bash scripts/dispatch/model-ship-rate.sh                 # last 24h, by model
#   bash scripts/dispatch/model-ship-rate.sh --by-harness    # last 24h, by harness
#   bash scripts/dispatch/model-ship-rate.sh --window 7d     # last 7 days
#   bash scripts/dispatch/model-ship-rate.sh --json           # JSON output

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

_GIT_COMMON="$(git -C "$REPO_ROOT" rev-parse --git-common-dir 2>/dev/null || echo ".git")"
if [[ "$_GIT_COMMON" == ".git" ]]; then MAIN_REPO="$REPO_ROOT"; else MAIN_REPO="$(cd "$_GIT_COMMON/.." && pwd)"; fi
AMBIENT="${CHUMP_AMBIENT_LOG:-$MAIN_REPO/.chump-locks/ambient.jsonl}"

AS_JSON=0
BY_HARNESS=0
WINDOW_HOURS=24
for arg in "$@"; do
    case "$arg" in
        --json) AS_JSON=1 ;;
        --by-harness) BY_HARNESS=1 ;;
        --window) ;;
    esac
done
# macOS seq counts down when start>end, so guard empty args.
if [[ $# -gt 0 ]]; then
for i in $(seq 1 $#); do
    arg="${!i}"
    if [[ "$arg" == "--window" ]]; then
        next=$((i+1))
        w="${!next:-24h}"
        case "$w" in
            *d) WINDOW_HOURS=$(( ${w%d} * 24 )) ;;
            *h) WINDOW_HOURS="${w%h}" ;;
            *)  WINDOW_HOURS="$w" ;;
        esac
    fi
done
fi

if [[ ! -f "$AMBIENT" ]]; then
    echo "(no ambient.jsonl found — no data)"
    exit 0
fi

# Compute cutoff timestamp using python3 (portable across macOS/Linux)
CUTOFF="$(python3 -c "
from datetime import datetime, timezone, timedelta
cutoff = datetime.now(timezone.utc) - timedelta(hours=$WINDOW_HOURS)
print(cutoff.strftime('%Y-%m-%dT%H:%M:%SZ'))
")"

python3 - "$AMBIENT" "$CUTOFF" "$AS_JSON" "$BY_HARNESS" <<'PYEOF'
import sys, json, collections

ambient_path, cutoff, as_json_str, by_harness_str = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
as_json = as_json_str == "1"
by_harness = by_harness_str == "1"

# Per-group accumulator (grouped by model or harness)
counts  = collections.defaultdict(int)
clippy  = collections.defaultdict(int)
tested  = collections.defaultdict(int)

with open(ambient_path, "r", errors="replace") as f:
    for raw in f:
        raw = raw.strip()
        if not raw:
            continue
        try:
            ev = json.loads(raw)
        except json.JSONDecodeError:
            continue
        if ev.get("kind") != "ship_grade" and ev.get("event") != "ship_grade":
            continue
        ts = ev.get("ts", "")
        if ts < cutoff:
            continue
        key = ev.get("harness" if by_harness else "model", "unknown") or "unknown"
        counts[key] += 1
        if ev.get("clippy_ok") is True or ev.get("clippy_ok") == "true":
            clippy[key] += 1
        if ev.get("test_added") is True or ev.get("test_added") == "true":
            tested[key] += 1

if not counts:
    label = "harnesses" if by_harness else "models"
    if as_json:
        print('{"window_hours":' + sys.argv[2][:4] + ',"' + label + '":[]}')
    else:
        print("(no ship_grade events in window)")
    sys.exit(0)

keys_sorted = sorted(counts.keys(), key=lambda k: counts[k], reverse=True)

if as_json:
    rows = []
    for k in keys_sorted:
        n = counts[k]
        rows.append({
            "harness" if by_harness else "model": k,
            "graded": n,
            "clippy_ok_pct": round(100 * clippy[k] / n) if n else None,
            "test_added_pct": round(100 * tested[k] / n) if n else None,
        })
    label = "harnesses" if by_harness else "models"
    print(json.dumps({"cutoff": cutoff, label: rows}, indent=2))
else:
    group_label = "Harness" if by_harness else "Model"
    print(f"Per-{group_label.lower()} ship breakdown (since {cutoff}):")
    print(f"  {group_label:<30}  {'graded':>6}  {'clippy_ok':>10}  {'test_added':>10}")
    print("  " + "─" * 62)
    for k in keys_sorted:
        n = counts[k]
        cok = f"{100 * clippy[k] // n}%" if n else "n/a"
        tadd = f"{100 * tested[k] // n}%" if n else "n/a"
        print(f"  {k:<30}  {n:>6}  {cok:>10}  {tadd:>10}")
PYEOF
