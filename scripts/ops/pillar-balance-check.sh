#!/usr/bin/env bash
# pillar-balance-check.sh — INFRA-902
#
# Analyzes pickable gap counts per pillar and emits alerts when
# the balance is unhealthy.
#
# Pickable = status:open + priority P0|P1 + effort xs|s|m + no TODO ACs
#
# Emits:
#   kind=pillar_balance_alert      when pillar count < PILLAR_FLOOR (default: 2)
#   kind=pillar_balance_overweight when pillar % > PILLAR_OVERWEIGHT_PCT (default: 50)
#
# Usage:
#   pillar-balance-check.sh [--floor N] [--overweight-pct PCT] [--dry-run] [--json]
#
# Exit codes:
#   0 = all pillars healthy
#   1 = one or more alert conditions fired
#
# Environment:
#   CHUMP_AMBIENT_LOG   Path to ambient.jsonl
#   REPO_ROOT           Repo root
#   PILLAR_FLOOR        Minimum pickable per pillar (default: 2)
#   PILLAR_OVERWEIGHT_PCT  Max pct before overweight alert (default: 50)

set -euo pipefail

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}"
AMBIENT="${CHUMP_AMBIENT_LOG:-$REPO_ROOT/.chump-locks/ambient.jsonl}"
FLOOR="${PILLAR_FLOOR:-2}"
OVERWEIGHT_PCT="${PILLAR_OVERWEIGHT_PCT:-50}"
DRY_RUN=0
JSON_OUT=0
ALERTS=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --floor)           FLOOR="$2";          shift 2 ;;
        --overweight-pct)  OVERWEIGHT_PCT="$2";  shift 2 ;;
        --dry-run)         DRY_RUN=1;            shift ;;
        --json)            JSON_OUT=1;            shift ;;
        -h|--help)
            echo "Usage: pillar-balance-check.sh [--floor N] [--overweight-pct PCT] [--dry-run] [--json]"
            exit 0 ;;
        *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
done

# ── Helpers ───────────────────────────────────────────────────────────────────

_ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }

_emit() {
    local kind="$1" pillar="$2" count="$3" extra="${4:-}"
    local ts
    ts="$(_ts)"
    if [[ "$DRY_RUN" -eq 1 ]]; then
        echo "[dry-run] would emit kind=$kind pillar=$pillar count=$count $extra" >&2
    else
        printf '{"ts":"%s","kind":"%s","pillar":"%s","count":%d,"floor":%d%s}\n' \
            "$ts" "$kind" "$pillar" "$count" "$FLOOR" "${extra:+,$extra}" \
            >> "$AMBIENT" 2>/dev/null || true
    fi
}

# ── Gather pickable counts via chump gap list ─────────────────────────────────
# Parse output: lines starting [open] with (P0|P1)/(xs|s|m) and no TODO in description

_gap_output=$(chump gap list --status open 2>/dev/null || true)

if [[ -z "$_gap_output" ]]; then
    echo "[pillar-balance-check] ERROR: chump gap list returned no output" >&2
    exit 1
fi

# Use python3 for reliable parsing
_counts=$(python3 -c "
import sys, re, json, collections

lines = '''$_gap_output'''.split('\n')

PILLARS = ['EFFECTIVE', 'CREDIBLE', 'RESILIENT', 'ZERO-WASTE', 'MISSION']
pillar_re = re.compile(r'\b(EFFECTIVE|CREDIBLE|RESILIENT|ZERO.WASTE|MISSION)\b', re.I)
pickable_re = re.compile(r'\(P[01]/(xs|s|m)\)')
todo_re = re.compile(r'\bTODO\b|\bTBD\b', re.I)

counts = {p: 0 for p in PILLARS}
counts['OTHER'] = 0
total = 0

for line in lines:
    if not line.startswith('[open]'):
        continue
    # Must be pickable priority/effort
    if not pickable_re.search(line):
        continue
    # Must not have TODO in description inline (chump gap list doesn't show ACs,
    # so we rely on the gap title not being TODO-stub)
    pillar = 'OTHER'
    m = pillar_re.search(line)
    if m:
        p = m.group(1).upper()
        if 'ZERO' in p or 'WASTE' in p:
            p = 'ZERO-WASTE'
        if p in counts:
            pillar = p
    counts[pillar] += 1
    total += 1

print(json.dumps({'counts': counts, 'total': total}))
" 2>/dev/null)

if [[ -z "$_counts" ]]; then
    echo "[pillar-balance-check] ERROR: could not parse gap counts" >&2
    exit 1
fi

TOTAL=$(echo "$_counts" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['total'])")

# ── Check each pillar ─────────────────────────────────────────────────────────

if [[ "$JSON_OUT" -eq 1 ]]; then
    echo "$_counts"
fi

echo "$_counts" | python3 -c "
import sys, json, math

data = json.load(sys.stdin)
counts = data['counts']
total = data['total']
floor = int('$FLOOR')
overweight_pct = int('$OVERWEIGHT_PCT')
dry_run = int('$DRY_RUN')
ambient = '$AMBIENT'

import subprocess, os
from datetime import datetime, timezone

PILLAR_ALERT = 'pillar_balance_alert'
PILLAR_OVERWEIGHT = 'pillar_balance_overweight'

def ts():
    return datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')

alerts = []

for pillar, count in sorted(counts.items()):
    if pillar == 'OTHER':
        continue
    pct = round(count / total * 100, 1) if total > 0 else 0
    print(f'  {pillar:<12} {count:>3} pickable  ({pct:.1f}% of {total})', end='')

    if count < floor:
        print(f'  ← ALERT: below floor={floor}')
        ev = {'ts': ts(), 'kind': PILLAR_ALERT, 'pillar': pillar, 'count': count, 'floor': floor}
        alerts.append(ev)
        if not dry_run:
            try:
                os.makedirs(os.path.dirname(ambient) or '.', exist_ok=True)
                with open(ambient, 'a') as f:
                    f.write(json.dumps(ev) + '\n')
            except Exception as e:
                print(f'  WARN: could not write to ambient: {e}', file=sys.stderr)
    elif total > 0 and pct > overweight_pct:
        print(f'  ← OVERWEIGHT: {pct:.1f}% > {overweight_pct}%')
        ev = {'ts': ts(), 'kind': PILLAR_OVERWEIGHT, 'pillar': pillar, 'count': count, 'floor': floor, 'pct': pct}
        alerts.append(ev)
        if not dry_run:
            try:
                os.makedirs(os.path.dirname(ambient) or '.', exist_ok=True)
                with open(ambient, 'a') as f:
                    f.write(json.dumps(ev) + '\n')
            except Exception as e:
                print(f'  WARN: could not write to ambient: {e}', file=sys.stderr)
    else:
        print(f'  OK')

if alerts:
    print(f'\n  {len(alerts)} alert(s) fired — check ambient.jsonl')
    sys.exit(1)
else:
    print('\n  All pillars healthy.')
"
_exit=$?
exit $_exit
