#!/usr/bin/env bash
# model-ship-rate.sh — CREDIBLE-025: per-model ship-rate breakdown from ambient.jsonl.
#
# Reads ship_grade events emitted by bot-merge.sh and groups by model.
# Shows: model | gaps_graded | clippy_ok% | test_added%
#
# Usage:
#   bash scripts/dispatch/model-ship-rate.sh             # last 24h
#   bash scripts/dispatch/model-ship-rate.sh --window 7d # last 7 days
#   bash scripts/dispatch/model-ship-rate.sh --json      # JSON output

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

_GIT_COMMON="$(git -C "$REPO_ROOT" rev-parse --git-common-dir 2>/dev/null || echo ".git")"
if [[ "$_GIT_COMMON" == ".git" ]]; then MAIN_REPO="$REPO_ROOT"; else MAIN_REPO="$(cd "$_GIT_COMMON/.." && pwd)"; fi
AMBIENT="${CHUMP_AMBIENT_LOG:-$MAIN_REPO/.chump-locks/ambient.jsonl}"

AS_JSON=0
WINDOW_HOURS=24
for arg in "$@"; do
    case "$arg" in
        --json) AS_JSON=1 ;;
        --window) ;;
    esac
done
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

python3 - "$AMBIENT" "$CUTOFF" "$AS_JSON" <<'PYEOF'
import sys, json, collections

ambient_path, cutoff, as_json_str = sys.argv[1], sys.argv[2], sys.argv[3]
as_json = as_json_str == "1"

# Per-model accumulators
counts  = collections.defaultdict(int)  # total graded
clippy  = collections.defaultdict(int)  # clippy_ok=true
tested  = collections.defaultdict(int)  # test_added=true

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
        model = ev.get("model", "unknown") or "unknown"
        counts[model] += 1
        if ev.get("clippy_ok") is True or ev.get("clippy_ok") == "true":
            clippy[model] += 1
        if ev.get("test_added") is True or ev.get("test_added") == "true":
            tested[model] += 1

if not counts:
    if as_json:
        print('{"window_hours":' + sys.argv[2][:4] + ',"models":[]}')
    else:
        print("(no ship_grade events in window)")
    sys.exit(0)

models_sorted = sorted(counts.keys(), key=lambda m: counts[m], reverse=True)

if as_json:
    rows = []
    for m in models_sorted:
        n = counts[m]
        rows.append({
            "model": m,
            "graded": n,
            "clippy_ok_pct": round(100 * clippy[m] / n) if n else None,
            "test_added_pct": round(100 * tested[m] / n) if n else None,
        })
    print(json.dumps({"cutoff": cutoff, "models": rows}, indent=2))
else:
    print(f"Per-model ship breakdown (since {cutoff}):")
    print(f"  {'model':<30}  {'graded':>6}  {'clippy_ok':>10}  {'test_added':>10}")
    print("  " + "─" * 62)
    for m in models_sorted:
        n = counts[m]
        cok = f"{100 * clippy[m] // n}%" if n else "n/a"
        tadd = f"{100 * tested[m] // n}%" if n else "n/a"
        print(f"  {m:<30}  {n:>6}  {cok:>10}  {tadd:>10}")
PYEOF
