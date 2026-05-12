#!/usr/bin/env bash
# cognition-ab-report.sh — META-045
# Compares ship rate + cycle time between cognition-stack cells A and B.
#
# Reads session_end events from the cell-specific ambient logs written by
# cognition-ab-setup.sh and prints a comparison table.
#
# Usage:
#   scripts/experiments/cognition-ab-report.sh
#   scripts/experiments/cognition-ab-report.sh --run-tag 20260512-150000
#   scripts/experiments/cognition-ab-report.sh --log-a /path/cell-A.jsonl --log-b /path/cell-B.jsonl
#
# Environment:
#   META045_RUN_TAG   match cell logs by run tag (default: latest)
#   META045_LOG_DIR   directory to search for cell logs (default: .chump-locks/meta045)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

RUN_TAG="${META045_RUN_TAG:-}"
LOG_DIR="${META045_LOG_DIR:-$REPO_ROOT/.chump-locks/meta045}"
LOG_A=""
LOG_B=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --run-tag)    RUN_TAG="$2"; shift 2 ;;
        --log-a)      LOG_A="$2"; shift 2 ;;
        --log-b)      LOG_B="$2"; shift 2 ;;
        --log-dir)    LOG_DIR="$2"; shift 2 ;;
        --help|-h)    sed -n '2,/^$/p' "$0" | sed 's/^# \?//'; exit 0 ;;
        *) echo "cognition-ab-report.sh: unknown argument: $1" >&2; exit 2 ;;
    esac
done

ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# ── Locate log files ──────────────────────────────────────────────────────────

if [[ -z "$LOG_A" && -z "$LOG_B" ]]; then
    if [[ -n "$RUN_TAG" ]]; then
        LOG_A="$LOG_DIR/cell-A-${RUN_TAG}.jsonl"
        LOG_B="$LOG_DIR/cell-B-${RUN_TAG}.jsonl"
    else
        # Find latest pair
        LOG_A=$(ls "$LOG_DIR"/cell-A-*.jsonl 2>/dev/null | sort | tail -1 || true)
        LOG_B=$(ls "$LOG_DIR"/cell-B-*.jsonl 2>/dev/null | sort | tail -1 || true)
    fi
fi

[[ -f "$LOG_A" ]] || { echo "ERROR: cell-A log not found: $LOG_A" >&2; exit 1; }
[[ -f "$LOG_B" ]] || { echo "ERROR: cell-B log not found: $LOG_B" >&2; exit 1; }

echo "[cognition-ab-report] cell-A log: $LOG_A"
echo "[cognition-ab-report] cell-B log: $LOG_B"
echo ""

# ── Python analysis ───────────────────────────────────────────────────────────
python3 - "$LOG_A" "$LOG_B" <<'PYEOF'
import sys, json, math

def load_events(path):
    events = []
    try:
        with open(path) as f:
            for line in f:
                line = line.strip()
                if not line: continue
                try: events.append(json.loads(line))
                except json.JSONDecodeError: pass
    except FileNotFoundError:
        pass
    return events

def analyse(events):
    shipped = [e for e in events if e.get('kind') == 'session_end' and e.get('outcome') == 'shipped']
    all_ends = [e for e in events if e.get('kind') == 'session_end']
    total = len(all_ends)
    ship_count = len(shipped)
    ship_rate = (ship_count / total * 100) if total > 0 else 0.0
    elapsed = [e.get('elapsed_seconds') for e in shipped if e.get('elapsed_seconds') is not None]
    cycle_h = (sum(elapsed) / len(elapsed) / 3600.0) if elapsed else None
    return {
        'ship_count': ship_count, 'total': total, 'ship_rate': ship_rate,
        'cycle_h': cycle_h, 'sample_n': len(elapsed),
    }

path_a, path_b = sys.argv[1], sys.argv[2]
ea, eb = load_events(path_a), load_events(path_b)

# Extract run config from cognition_ab_run_start events
def cell_config(events):
    for e in events:
        if e.get('kind') == 'cognition_ab_run_start':
            return f"lessons={e.get('lessons_at_spawn_n',0)}, embed={e.get('embedding_enabled',False)}"
    return 'unknown'

cfg_a, cfg_b = cell_config(ea), cell_config(eb)
ra, rb = analyse(ea), analyse(eb)

print(f"{'Metric':<28} {'Cell A':>12} {'Cell B':>12}")
print("-" * 55)
print(f"{'Config':<28} {cfg_a:>12} {cfg_b:>12}")
print(f"{'Total sessions':<28} {ra['total']:>12} {rb['total']:>12}")
print(f"{'Shipped':<28} {ra['ship_count']:>12} {rb['ship_count']:>12}")
print(f"{'Ship rate':<28} {ra['ship_rate']:>11.1f}% {rb['ship_rate']:>11.1f}%")
if ra['cycle_h'] is not None or rb['cycle_h'] is not None:
    ca = f"{ra['cycle_h']:.2f}h" if ra['cycle_h'] is not None else 'n/a'
    cb = f"{rb['cycle_h']:.2f}h" if rb['cycle_h'] is not None else 'n/a'
    print(f"{'Avg cycle time':<28} {ca:>12} {cb:>12}")

# Verdict
print("")
if ra['total'] < 5 or rb['total'] < 5:
    print("WARNING: sample too small for statistical conclusions (need >=5 per cell).")
    verdict = "insufficient_data"
elif abs(ra['ship_rate'] - rb['ship_rate']) < 5.0:
    print("VERDICT: no meaningful ship-rate difference (< 5pp delta).")
    verdict = "no_effect"
elif ra['ship_rate'] > rb['ship_rate']:
    delta = ra['ship_rate'] - rb['ship_rate']
    print(f"VERDICT: Cell A (cognition ON) outperforms by {delta:.1f}pp ship rate.")
    verdict = "cognition_wins"
else:
    delta = rb['ship_rate'] - ra['ship_rate']
    print(f"VERDICT: Cell B (cognition OFF) outperforms by {delta:.1f}pp ship rate.")
    verdict = "baseline_wins"

sys.exit(0 if verdict != "insufficient_data" else 1)
PYEOF

# ── Emit comparison event to main ambient log ────────────────────────────────

MAIN_AMBIENT="${CHUMP_AMBIENT_LOG:-$REPO_ROOT/.chump-locks/ambient.jsonl}"
printf '{"ts":"%s","kind":"cognition_ab_comparison","log_a":"%s","log_b":"%s","run_tag":"%s"}\n' \
    "$(ts)" "$LOG_A" "$LOG_B" "${RUN_TAG:-auto}" >> "$MAIN_AMBIENT" 2>/dev/null || true
