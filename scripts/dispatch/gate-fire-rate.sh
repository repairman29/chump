#!/usr/bin/env bash
# gate-fire-rate.sh — CREDIBLE-048
#
# Compute per-gate fire-rate statistics from ambient.jsonl.
# Reads gate_check_start and gate_check_result events and summarises
# how often each gate has fired (outcome=fail), passed, been bypassed,
# or skipped over a given time window.
#
# Output: ~/.chump/metrics/gate-fire-rate.jsonl (one summary per run)
#         Prints human-readable table to stdout.
#
# Usage:
#   scripts/dispatch/gate-fire-rate.sh                     # last 7 days
#   scripts/dispatch/gate-fire-rate.sh --window 24h        # last 24 hours
#   scripts/dispatch/gate-fire-rate.sh --window 30d        # last 30 days
#   scripts/dispatch/gate-fire-rate.sh --gate CREDIBLE-026 # one gate
#   scripts/dispatch/gate-fire-rate.sh --json              # JSON output only
#
# Environment:
#   CHUMP_AMBIENT_LOG     path to ambient.jsonl
#   CHUMP_METRICS_DIR     directory for gate-fire-rate.jsonl output
#
# Surfaces in: chump fleet status --gates

set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || cd "$(dirname "$0")/../.." && pwd)"
AMBIENT="${CHUMP_AMBIENT_LOG:-${REPO_ROOT}/.chump-locks/ambient.jsonl}"
METRICS_DIR="${CHUMP_METRICS_DIR:-${HOME}/.chump/metrics}"
mkdir -p "$METRICS_DIR" 2>/dev/null || true

WINDOW_SEC=$(( 7 * 86400 ))  # default: 7 days
GATE_FILTER=""
JSON_ONLY=false

prev_arg=""
for arg in "$@"; do
    case "$arg" in
        --json) JSON_ONLY=true ;;
        --gate|--window) ;;  # consumed below
    esac
    if [[ "$prev_arg" == "--window" ]]; then
        case "$arg" in
            *h) WINDOW_SEC=$(( ${arg%h} * 3600 )) ;;
            *d) WINDOW_SEC=$(( ${arg%d} * 86400 )) ;;
            *)  WINDOW_SEC="$arg" ;;
        esac
    fi
    [[ "$prev_arg" == "--gate" ]] && GATE_FILTER="$arg"
    prev_arg="$arg"
done

if [[ ! -f "$AMBIENT" ]]; then
    echo "[gate-fire-rate] ambient.jsonl not found at $AMBIENT"
    exit 0
fi

python3 - <<PYEOF
import json, sys, os, time
from collections import defaultdict

ambient_path = "$AMBIENT"
metrics_dir  = "$METRICS_DIR"
window_sec   = $WINDOW_SEC
gate_filter  = "$GATE_FILTER"
json_only    = "$JSON_ONLY" == "true"

now = time.time()
cutoff = now - window_sec

# gate_name → {total_checks, fires, passes, bypasses, skips}
stats = defaultdict(lambda: {"total_checks": 0, "fires": 0, "passes": 0,
                               "bypasses": 0, "skips": 0, "last_fire": None})

try:
    with open(ambient_path, encoding="utf-8", errors="replace") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                ev = json.loads(line)
            except json.JSONDecodeError:
                continue
            if ev.get("kind") not in ("gate_check_start", "gate_check_result"):
                continue
            gate = ev.get("gate", "")
            if not gate:
                continue
            if gate_filter and gate != gate_filter:
                continue
            # Parse timestamp
            ts_str = ev.get("ts", "")
            try:
                import datetime
                ts = datetime.datetime.strptime(ts_str, "%Y-%m-%dT%H:%M:%SZ").timestamp()
            except Exception:
                continue
            if ts < cutoff:
                continue
            if ev["kind"] == "gate_check_start":
                stats[gate]["total_checks"] += 1
            elif ev["kind"] == "gate_check_result":
                outcome = ev.get("outcome", "")
                if outcome == "fail":
                    stats[gate]["fires"] += 1
                    stats[gate]["last_fire"] = ts_str
                elif outcome in ("pass",):
                    stats[gate]["passes"] += 1
                elif outcome == "bypassed":
                    stats[gate]["bypasses"] += 1
                elif outcome == "skipped":
                    stats[gate]["skips"] += 1
except OSError as e:
    print(f"[gate-fire-rate] ERROR reading ambient: {e}", file=sys.stderr)
    sys.exit(1)

if not stats:
    if not json_only:
        print(f"[gate-fire-rate] No gate telemetry in the last {window_sec//3600}h")
    sys.exit(0)

window_h = window_sec / 3600
ts_now = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(now))

summary = {
    "ts": ts_now,
    "window_h": window_h,
    "gates": {}
}

for gate in sorted(stats):
    s = stats[gate]
    total = s["total_checks"]
    fire_rate = s["fires"] / total if total > 0 else 0.0
    summary["gates"][gate] = {
        "total_checks": total,
        "fires": s["fires"],
        "passes": s["passes"],
        "bypasses": s["bypasses"],
        "skips": s["skips"],
        "fire_rate_pct": round(fire_rate * 100, 1),
        "last_fire": s["last_fire"],
    }

# Write to metrics file
metrics_path = os.path.join(metrics_dir, "gate-fire-rate.jsonl")
try:
    with open(metrics_path, "a", encoding="utf-8") as f:
        f.write(json.dumps(summary) + "\n")
except OSError:
    pass  # metrics write is best-effort

if json_only:
    print(json.dumps(summary, indent=2))
    sys.exit(0)

# Human-readable table
window_str = f"{window_h:.0f}h" if window_h < 168 else f"{window_h/24:.0f}d"
print(f"=== gate-fire-rate [{window_str} window, {ts_now}] ===")
print(f"{'Gate':<30} {'Checks':>7} {'Fires':>6} {'FireRate':>9} {'Bypasses':>9} {'Skips':>6} {'LastFire'}")
print("-" * 90)
for gate, s in sorted(summary["gates"].items()):
    last = s["last_fire"] or "never"
    print(f"{gate:<30} {s['total_checks']:>7} {s['fires']:>6} {s['fire_rate_pct']:>8.1f}% "
          f"{s['bypasses']:>9} {s['skips']:>6}  {last}")
print()
print(f"Metrics appended to: {metrics_path}")
PYEOF
