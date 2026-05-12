#!/usr/bin/env bash
# classify-incident.sh — INFRA-896
# Reads ambient.jsonl tail, classifies incidents by event kind and severity,
# and emits kind=incident_classified to ambient.jsonl with aggregated counts.
#
# Severity mapping (P0 = most critical):
#   P0: fleet_wedge
#   P1: silent_agent, silent_agent_cluster
#   P2: pr_stuck
#   P3: cascade_backoff, cascade_backoff_pre_sleep
#
# Usage:
#   scripts/ops/classify-incident.sh [--window S] [--tail N] [--dry-run] [--json]
#
# Environment:
#   CHUMP_INCIDENT_WINDOW_S   Look-back window in seconds (default: 3600 = 1h).
#   CHUMP_INCIDENT_DISABLE=1  Skip classification (opt-out).
#
# Exit codes:
#   0  No incidents detected (or disabled).
#   1  One or more incidents classified (non-zero for alerting integration).
#   2  Usage error.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
AMBIENT="${CHUMP_AMBIENT_LOG:-$REPO_ROOT/.chump-locks/ambient.jsonl}"

WINDOW_S="${CHUMP_INCIDENT_WINDOW_S:-3600}"
TAIL_N=500
DRY_RUN=0
JSON_MODE=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --window)   WINDOW_S="$2"; shift 2 ;;
        --tail)     TAIL_N="$2";   shift 2 ;;
        --dry-run)  DRY_RUN=1;     shift ;;
        --json)     JSON_MODE=1;   shift ;;
        --help|-h)
            sed -n '2,/^$/p' "$0" | sed 's/^# \?//'
            exit 0
            ;;
        *) echo "classify-incident.sh: unknown argument: $1" >&2; exit 2 ;;
    esac
done

if [[ "${CHUMP_INCIDENT_DISABLE:-0}" == "1" ]]; then
    echo "[classify-incident] CHUMP_INCIDENT_DISABLE=1 — skipping"
    exit 0
fi

SESSION="${SESSION_ID:-$(hostname)-$$}"
ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }

if [[ ! -f "$AMBIENT" ]]; then
    [[ "$JSON_MODE" -eq 0 ]] && echo "[classify-incident] ambient.jsonl not found at $AMBIENT"
    exit 0
fi

# Read the tail of ambient.jsonl and classify incidents via Python.
tail -"$TAIL_N" "$AMBIENT" | python3 -c "
import sys, json, time, os

WINDOW_S = int('$WINDOW_S')
DRY_RUN  = int('$DRY_RUN')
JSON_MODE= int('$JSON_MODE')
AMBIENT  = '$AMBIENT'
SESSION  = '$SESSION'

# Severity mapping: kind -> (severity_label, priority)
SEVERITY = {
    'fleet_wedge':              ('P0', 'critical'),
    'silent_agent':             ('P1', 'high'),
    'silent_agent_cluster':     ('P1', 'high'),
    'pr_stuck':                 ('P2', 'medium'),
    'cascade_backoff':          ('P3', 'low'),
    'cascade_backoff_pre_sleep':('P3', 'low'),
}

now = time.time()
cutoff = now - WINDOW_S

counts = {}   # kind -> count
for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    try:
        ev = json.loads(line)
    except (json.JSONDecodeError, ValueError):
        continue
    kind = ev.get('kind', '')
    if kind not in SEVERITY:
        continue
    # Parse ts to filter by window
    ts_str = ev.get('ts', '')
    if ts_str:
        try:
            from datetime import datetime, timezone
            dt = datetime.fromisoformat(ts_str.replace('Z', '+00:00'))
            ev_epoch = dt.timestamp()
        except Exception:
            ev_epoch = now  # assume recent if unparseable
    else:
        ev_epoch = now
    if ev_epoch < cutoff:
        continue
    counts[kind] = counts.get(kind, 0) + 1

if not counts:
    if JSON_MODE == 0:
        print('[classify-incident] No incidents in window=%ds' % WINDOW_S)
    sys.exit(0)

import datetime as dt_mod

def ts_now():
    return dt_mod.datetime.now(dt_mod.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')

# Emit one incident_classified event per kind.
incidents = 0
for kind, count in sorted(counts.items(), key=lambda kv: SEVERITY[kv[0]][0]):
    severity_label, priority = SEVERITY[kind]
    payload = json.dumps({
        'ts': ts_now(),
        'kind': 'incident_classified',
        'session': SESSION,
        'severity': severity_label,
        'trigger_kind': kind,
        'count': count,
        'window_s': WINDOW_S,
    })
    if DRY_RUN:
        print('[classify-incident] [dry-run] would emit: ' + payload, file=sys.stderr)
    else:
        try:
            with open(AMBIENT, 'a') as f:
                f.write(payload + '\n')
        except OSError:
            pass
    if JSON_MODE:
        print(payload)
    else:
        print('[classify-incident] %s %s=%d (%s)' % (severity_label, kind, count, priority))
    incidents += 1

sys.exit(1 if incidents > 0 else 0)
"
