#!/usr/bin/env bash
# gap-perf-report.sh — INFRA-906
#
# Reads gap_perf_sample events from ambient.jsonl and reports
# p50/p95 latency per phase for a given gap (or all gaps).
#
# Usage:
#   gap-perf-report.sh [--gap GAP-ID] [--phase PHASE] [--last N] [--svg path.json]
#
# Options:
#   --gap GAP-ID    Filter to a specific gap (default: all gaps)
#   --phase PHASE   Filter to a specific phase (default: all phases)
#   --last N        Use only the last N samples (default: 20)
#   --svg PATH      Write chrome-tracing-format JSON to PATH (flame chart)
#
# Outputs a text table:
#   GAP_ID    PHASE    N    p50_ms    p95_ms    last_ms    last_exit
#
# Environment:
#   CHUMP_AMBIENT_LOG   Path to ambient.jsonl
#   REPO_ROOT           Repo root

set -euo pipefail

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}"
AMBIENT="${CHUMP_AMBIENT_LOG:-$REPO_ROOT/.chump-locks/ambient.jsonl}"
FILTER_GAP=""
FILTER_PHASE=""
LAST_N=20
SVG_PATH=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --gap)   FILTER_GAP="$2";   shift 2 ;;
        --phase) FILTER_PHASE="$2"; shift 2 ;;
        --last)  LAST_N="$2";       shift 2 ;;
        --svg)   SVG_PATH="$2";     shift 2 ;;
        -h|--help)
            echo "Usage: gap-perf-report.sh [--gap GAP-ID] [--phase PHASE] [--last N] [--svg PATH]"
            exit 0 ;;
        *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
done

if [[ ! -f "$AMBIENT" ]]; then
    echo "[gap-perf-report] No ambient.jsonl at $AMBIENT" >&2
    exit 1
fi

# ── Extract + compute p50/p95 ─────────────────────────────────────────────────
python3 - <<PYEOF
import json, sys, os, math, collections

ambient = "$AMBIENT"
filter_gap = "$FILTER_GAP"
filter_phase = "$FILTER_PHASE"
last_n = int("$LAST_N")
svg_path = "$SVG_PATH"

# Read all gap_perf_sample events
samples = []
try:
    with open(ambient) as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                ev = json.loads(line)
            except json.JSONDecodeError:
                continue
            if ev.get("kind") != "gap_perf_sample":
                continue
            if filter_gap and ev.get("gap_id") != filter_gap:
                continue
            if filter_phase and ev.get("phase") != filter_phase:
                continue
            samples.append(ev)
except FileNotFoundError:
    print(f"No ambient file: {ambient}", file=sys.stderr)
    sys.exit(1)

if not samples:
    print("No gap_perf_sample events found (try --gap ALL or check ambient.jsonl)")
    sys.exit(0)

# Group by (gap_id, phase), take last N
groups = collections.defaultdict(list)
for s in samples:
    key = (s.get("gap_id","?"), s.get("phase","?"))
    groups[key].append(s)

def percentile(vals, pct):
    if not vals:
        return 0
    s = sorted(vals)
    idx = max(0, min(len(s)-1, int(math.ceil(len(s) * pct / 100)) - 1))
    return s[idx]

print(f"{'GAP_ID':<20} {'PHASE':<10} {'N':>4}  {'p50_ms':>8}  {'p95_ms':>8}  {'last_ms':>8}  {'last_exit':>9}")
print("-" * 80)

rows = []
for (gap_id, phase), evs in sorted(groups.items()):
    evs_last = evs[-last_n:]
    durations = [e.get("duration_ms", 0) for e in evs_last]
    p50 = percentile(durations, 50)
    p95 = percentile(durations, 95)
    last_ms = durations[-1] if durations else 0
    last_exit = evs_last[-1].get("exit_code", "?") if evs_last else "?"
    n = len(evs_last)
    print(f"{gap_id:<20} {phase:<10} {n:>4}  {p50:>8}  {p95:>8}  {last_ms:>8}  {last_exit!s:>9}")
    rows.append((gap_id, phase, n, p50, p95, last_ms, last_exit, evs_last))

# ── Chrome-tracing format JSON (flame chart) ──────────────────────────────────
if svg_path:
    trace_events = []
    pid = 1
    tid_map = {}
    for (gap_id, phase, n, p50, p95, last_ms, last_exit, evs_last) in rows:
        tid = tid_map.setdefault(phase, len(tid_map) + 1)
        for i, ev in enumerate(evs_last):
            ts_us = i * 1_000_000  # synthetic: space events 1s apart
            dur_us = ev.get("duration_ms", 0) * 1000
            trace_events.append({
                "name": f"{gap_id}/{phase}",
                "cat": "gap_perf",
                "ph": "X",
                "ts": ts_us,
                "dur": dur_us,
                "pid": pid,
                "tid": tid,
                "args": {
                    "gap_id": gap_id,
                    "phase": phase,
                    "duration_ms": ev.get("duration_ms", 0),
                    "exit_code": ev.get("exit_code", -1),
                    "host": ev.get("host", "?"),
                },
            })
    output = {
        "traceEvents": trace_events,
        "displayTimeUnit": "ms",
        "otherData": {"source": "chump gap-perf-report INFRA-906"},
    }
    try:
        with open(svg_path, "w") as f:
            json.dump(output, f, indent=2)
        print(f"\nFlame chart JSON written to: {svg_path}")
        print(f"Load in chrome://tracing or https://ui.perfetto.dev")
    except Exception as e:
        print(f"ERROR writing flame chart: {e}", file=sys.stderr)
        sys.exit(1)
PYEOF
