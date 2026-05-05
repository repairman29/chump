#!/usr/bin/env bash
# cog-041-quality-vs-recency.sh — EVAL-099
#
# Post-hoc analysis of COG-043 telemetry. Pairs `lessons_shown` events
# with their `lesson_applied` / `lesson_not_applied` grades from
# ambient.jsonl (+ rotated archives) and computes the per-mode
# lesson-applied rate.
#
# Methodology locked in docs/eval/preregistered/EVAL-099.md.
# Decision rule: H1 accepted iff n_A>=30 AND n_B>=30 AND delta_pp>=+10.

set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
DATE=$(date +%Y-%m-%d)
OUT="${EVAL_OUT:-$REPO_ROOT/docs/eval/COG-041-quality-vs-recency-$DATE.md}"
LOCK_DIR="$REPO_ROOT/.chump-locks"

# Source: live ambient.jsonl + rotated archives (INFRA-122).
# Decompress archives so the python aggregator sees one stream.
TMPDIR_BASE="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_BASE"' EXIT
COMBINED="$TMPDIR_BASE/ambient-all.jsonl"

if [[ -f "$LOCK_DIR/ambient.jsonl" ]]; then
    cat "$LOCK_DIR/ambient.jsonl" > "$COMBINED"
fi
for archive in "$LOCK_DIR"/ambient.jsonl.*.gz; do
    [[ -f "$archive" ]] || continue
    gunzip -c "$archive" >> "$COMBINED" 2>/dev/null || true
done

if [[ ! -s "$COMBINED" ]]; then
    {
        echo "# EVAL-099: COG-041 quality vs recency-frequency"
        echo
        echo "Generated: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
        echo "Methodology: docs/eval/preregistered/EVAL-099.md"
        echo
        echo "## Verdict: INSUFFICIENT_DATA"
        echo
        echo "No telemetry events found in $LOCK_DIR/ambient.jsonl. COG-043 may not"
        echo "be deployed yet, or no \`chump --briefing\` calls have run since deploy."
    } > "$OUT"
    echo "wrote $OUT  (INSUFFICIENT_DATA: no telemetry stream)"
    exit 0
fi

# ── Aggregate via python3 (cleaner than awk for the indexing) ─────────────
python3 - "$COMBINED" "$OUT" <<'PYEOF'
import json
import sys
from collections import defaultdict
from datetime import datetime, timedelta

src = sys.argv[1]
out_path = sys.argv[2]

# Index by (gap_id, session_id)
shown = {}      # (gap, session) -> {ts, mode, directives, gap_priority?}
grades = defaultdict(list)  # (gap, session) -> [(ts, applied, directive)]

def parse_ts(s):
    try:
        return datetime.fromisoformat(s.replace('Z', '+00:00'))
    except Exception:
        return None

with open(src) as f:
    for line in f:
        line = line.strip()
        if not line:
            continue
        try:
            d = json.loads(line)
        except Exception:
            continue
        kind = d.get('kind') or d.get('event')
        if kind == 'lessons_shown':
            key = (d.get('gap_id', ''), d.get('session_id', ''))
            ts = parse_ts(d.get('ts', ''))
            existing = shown.get(key)
            # Keep the most-recent shown per key (per prereg pairing rule).
            if existing is None or (ts and ts > existing['ts_parsed']):
                shown[key] = {
                    'ts': d.get('ts', ''),
                    'ts_parsed': ts or datetime.min,
                    'mode': d.get('mode', 'unknown'),
                    'directives': d.get('directives', []) or [],
                }
        elif kind in ('lesson_applied', 'lesson_not_applied'):
            key = (d.get('gap_id', ''), d.get('session_id', ''))
            ts = parse_ts(d.get('ts', ''))
            grades[key].append({
                'ts_parsed': ts,
                'applied': (kind == 'lesson_applied'),
                'directive': d.get('directive', ''),
                'matched': d.get('matched_keywords', 0),
                'total': d.get('total_keywords', 0),
            })

# Pair: each grade event is associated with the latest preceding
# `lessons_shown` for the same key, within 7 days.
PAIRING_WINDOW = timedelta(days=7)
cell_counts = defaultdict(lambda: {'applied': 0, 'not_applied': 0, 'cycles': 0})
cell_directive_overlap = defaultdict(list)
cell_efforts = defaultdict(list)
fallback_seen = 0
total_semantic_invocations = 0

for key, gevents in grades.items():
    s = shown.get(key)
    if s is None:
        continue
    mode = s['mode']
    if mode == 'semantic':
        total_semantic_invocations += 1
    if mode == 'recency_fallback_from_semantic':
        fallback_seen += 1
        # Per prereg, fallback events are reported separately, not in A or B.
        continue
    cell = mode  # 'semantic' or 'recency'
    if cell not in ('semantic', 'recency'):
        continue
    cycles_for_key = 0
    for g in gevents:
        if g['ts_parsed'] is None or s['ts_parsed'] is None:
            continue
        if g['ts_parsed'] < s['ts_parsed']:
            continue  # grade before show — wrong order
        if g['ts_parsed'] - s['ts_parsed'] > PAIRING_WINDOW:
            continue  # stale
        if g['applied']:
            cell_counts[cell]['applied'] += 1
        else:
            cell_counts[cell]['not_applied'] += 1
        cell_directive_overlap[cell].append(g['matched'])
        cycles_for_key = 1
    cell_counts[cell]['cycles'] += cycles_for_key

# Compute applied-rate per cell
def rate(cell):
    a = cell_counts[cell]['applied']
    n = cell_counts[cell]['applied'] + cell_counts[cell]['not_applied']
    return (a / n * 100.0) if n > 0 else None

rate_A = rate('recency')
rate_B = rate('semantic')

n_A = cell_counts['recency']['applied'] + cell_counts['recency']['not_applied']
n_B = cell_counts['semantic']['applied'] + cell_counts['semantic']['not_applied']

verdict = 'INSUFFICIENT_DATA'
verdict_reason = ''
delta_pp = None
if n_A >= 30 and n_B >= 30 and rate_A is not None and rate_B is not None:
    delta_pp = rate_B - rate_A
    if delta_pp >= 10.0:
        verdict = 'ACCEPT_H1'
        verdict_reason = (
            f'semantic mode applied-rate ({rate_B:.1f}%) exceeds recency-frequency '
            f'({rate_A:.1f}%) by {delta_pp:+.1f}pp >= +10pp threshold'
        )
    else:
        verdict = 'ACCEPT_H0'
        verdict_reason = (
            f'semantic-vs-recency delta = {delta_pp:+.1f}pp does not clear the +10pp '
            'threshold; default-OFF gating stays'
        )
else:
    verdict_reason = (
        f'need n>=30 per cell; have n_A={n_A} (recency), n_B={n_B} (semantic). '
        'Re-run after more usage accumulates.'
    )

# Median directive-overlap (the circular-signal control)
def median(xs):
    if not xs: return None
    xs = sorted(xs)
    m = len(xs) // 2
    return xs[m] if len(xs) % 2 == 1 else (xs[m-1] + xs[m]) / 2

med_A = median(cell_directive_overlap['recency'])
med_B = median(cell_directive_overlap['semantic'])
fallback_rate = (fallback_seen / total_semantic_invocations * 100.0) if total_semantic_invocations > 0 else 0.0

with open(out_path, 'w') as f:
    f.write('# EVAL-099: COG-041 quality vs recency-frequency\n\n')
    f.write(f'Generated: {datetime.utcnow().isoformat(timespec="seconds")}Z\n')
    f.write('Methodology: docs/eval/preregistered/EVAL-099.md\n\n')
    f.write(f'## Verdict: **{verdict}**\n\n')
    f.write(f'_{verdict_reason}_\n\n')
    f.write('## Counts\n\n')
    f.write('| Cell | Mode | Applied | Not applied | n | Applied rate |\n')
    f.write('|------|------|---------|-------------|---|--------------|\n')
    for label, cell_name in [('A', 'recency'), ('B', 'semantic')]:
        a = cell_counts[cell_name]['applied']
        na = cell_counts[cell_name]['not_applied']
        n = a + na
        r = (a / n * 100.0) if n > 0 else 0.0
        f.write(f'| {label} | {cell_name} | {a} | {na} | {n} | {r:.1f}% |\n')
    f.write('\n')
    if delta_pp is not None:
        f.write(f'**Delta (B - A):** {delta_pp:+.1f}pp\n\n')
    f.write('## Diagnostics\n\n')
    f.write(f'- Mode-C (semantic→recency fallback) rate: {fallback_rate:.1f}% of {total_semantic_invocations} semantic invocations\n')
    if total_semantic_invocations >= 10 and fallback_rate >= 50.0:
        f.write('  - **WARNING:** more than half of semantic invocations fell back to recency. '
                'COG-041\'s tokenizer may be too restrictive, or the lesson corpus too narrow. '
                'Review tokenizer (lib/STOPWORDS) before trusting any verdict above.\n')
    f.write(f'- Median directive-keyword-overlap per grade event (circular-signal control):\n')
    f.write(f'  - Cell A (recency): {med_A}\n')
    f.write(f'  - Cell B (semantic): {med_B}\n')
    if med_A is not None and med_B is not None and abs(med_B - med_A) < 0.5:
        f.write('  - Note: cells A and B have similar directive-keyword-overlap medians — '
                'any applied-rate advantage in B is **less likely to be a measurement artifact**.\n')
    f.write('\n')
    f.write('## Per-prereg prohibited claims\n\n')
    f.write('- This eval CANNOT claim semantic ranking is "provably best" — only that on this corpus, on this matcher, it has higher applied-rate by >= 10pp.\n')
    f.write('- The default flip is operator-discretion, not automatic from this report.\n')

print(f'wrote {out_path}')
print(f'Verdict: {verdict}')
print(f'  n_A (recency)  = {n_A}')
print(f'  n_B (semantic) = {n_B}')
if delta_pp is not None:
    print(f'  delta = {delta_pp:+.1f}pp')
PYEOF
