#!/usr/bin/env bash
# analyze-ab-results.sh — Compute deltas between consciousness ON and OFF baselines.
#
# Reads logs/study-ON-baseline.json and logs/study-OFF-baseline.json,
# computes metric deltas, and writes logs/study-analysis.json.

set -euo pipefail

ROOT="${CHUMP_HOME:-$(cd "$(dirname "$0")/.." && pwd)}"
LOG_DIR="$ROOT/logs"

ON_FILE="$LOG_DIR/study-ON-baseline.json"
OFF_FILE="$LOG_DIR/study-OFF-baseline.json"
ON_TIMINGS="$LOG_DIR/study-ON-timings.jsonl"
OFF_TIMINGS="$LOG_DIR/study-OFF-timings.jsonl"
OUTPUT="$LOG_DIR/study-analysis.json"

if [[ ! -f "$ON_FILE" ]] || [[ ! -f "$OFF_FILE" ]]; then
  echo "ERROR: Missing baseline files. Run run-consciousness-study.sh first."
  exit 1
fi

echo "  Analyzing ON vs OFF baselines..."

python3 -c "
import json, sys, statistics

with open('$ON_FILE') as f:
    on = json.load(f)
with open('$OFF_FILE') as f:
    off = json.load(f)

# Helper: safe delta
def delta(on_val, off_val):
    on_v = float(on_val or 0)
    off_v = float(off_val or 0)
    d = on_v - off_v
    pct = ((on_v - off_v) / off_v * 100) if off_v != 0 else (100 if on_v > 0 else 0)
    return {'on': on_v, 'off': off_v, 'delta': round(d, 4), 'pct_change': round(pct, 1)}

# Load timings
on_timings = []
off_timings = []
try:
    with open('$ON_TIMINGS') as f:
        for line in f:
            line = line.strip()
            if line:
                on_timings.append(json.loads(line))
except: pass
try:
    with open('$OFF_TIMINGS') as f:
        for line in f:
            line = line.strip()
            if line:
                off_timings.append(json.loads(line))
except: pass

on_ok_times = [t['elapsed_secs'] for t in on_timings if t.get('status') == 'ok']
off_ok_times = [t['elapsed_secs'] for t in off_timings if t.get('status') == 'ok']

timing_analysis = {
    'on_mean_secs': round(statistics.mean(on_ok_times), 2) if on_ok_times else 0,
    'off_mean_secs': round(statistics.mean(off_ok_times), 2) if off_ok_times else 0,
    'on_median_secs': round(statistics.median(on_ok_times), 2) if on_ok_times else 0,
    'off_median_secs': round(statistics.median(off_ok_times), 2) if off_ok_times else 0,
    'on_total_secs': sum(on_ok_times),
    'off_total_secs': sum(off_ok_times),
    'on_prompts_ok': len(on_ok_times),
    'off_prompts_ok': len(off_ok_times),
    'on_prompts_fail': len([t for t in on_timings if t.get('status') != 'ok']),
    'off_prompts_fail': len([t for t in off_timings if t.get('status') != 'ok']),
}

# Per-prompt comparison
prompt_comparison = []
on_by_prompt = {t['prompt']: t for t in on_timings}
off_by_prompt = {t['prompt']: t for t in off_timings}
for prompt in sorted(set(list(on_by_prompt.keys()) + list(off_by_prompt.keys()))):
    on_t = on_by_prompt.get(prompt, {})
    off_t = off_by_prompt.get(prompt, {})
    prompt_comparison.append({
        'prompt': prompt,
        'on_status': on_t.get('status', 'missing'),
        'off_status': off_t.get('status', 'missing'),
        'on_secs': on_t.get('elapsed_secs', 0),
        'off_secs': off_t.get('elapsed_secs', 0),
        'delta_secs': on_t.get('elapsed_secs', 0) - off_t.get('elapsed_secs', 0),
    })

analysis = {
    'study_id': on.get('study_metadata', {}).get('study_id', 'unknown'),
    'model': on.get('study_metadata', {}).get('model', 'unknown'),
    'hardware': on.get('study_metadata', {}).get('hardware', 'unknown'),
    'metrics': {
        'prediction_count': delta(
            on.get('surprise', {}).get('total_predictions', 0),
            off.get('surprise', {}).get('total_predictions', 0)
        ),
        'mean_surprisal': delta(
            on.get('surprise', {}).get('mean_surprisal', 0),
            off.get('surprise', {}).get('mean_surprisal', 0)
        ),
        'high_surprise_pct': delta(
            on.get('surprise', {}).get('high_surprise_pct', 0),
            off.get('surprise', {}).get('high_surprise_pct', 0)
        ),
        'memory_graph_triples': delta(
            on.get('memory_graph', {}).get('triple_count', 0),
            off.get('memory_graph', {}).get('triple_count', 0)
        ),
        'memory_graph_entities': delta(
            on.get('memory_graph', {}).get('unique_entities', 0),
            off.get('memory_graph', {}).get('unique_entities', 0)
        ),
        'causal_lessons': delta(
            on.get('counterfactual', {}).get('lesson_count', 0),
            off.get('counterfactual', {}).get('lesson_count', 0)
        ),
        'episodes': delta(
            on.get('episodes', {}).get('total', 0),
            off.get('episodes', {}).get('total', 0)
        ),
        'wall_time': delta(
            on.get('study_metadata', {}).get('wall_time_secs', 0),
            off.get('study_metadata', {}).get('wall_time_secs', 0)
        ),
    },
    'timing': timing_analysis,
    'prompt_comparison': prompt_comparison,
    'on_metadata': on.get('study_metadata', {}),
    'off_metadata': off.get('study_metadata', {}),
}

# Add verdict
verdicts = []
m = analysis['metrics']
if m['prediction_count']['delta'] > 0:
    verdicts.append(f\"Consciousness ON generated {int(m['prediction_count']['delta'])} more predictions ({m['prediction_count']['pct_change']}% increase)\")
if m['memory_graph_triples']['delta'] > 0:
    verdicts.append(f\"Memory graph grew {int(m['memory_graph_triples']['delta'])} more triples with consciousness ON\")
if m['causal_lessons']['delta'] > 0:
    verdicts.append(f\"Consciousness ON produced {int(m['causal_lessons']['delta'])} more causal lessons\")

latency_delta = timing_analysis['on_mean_secs'] - timing_analysis['off_mean_secs']
if latency_delta > 0:
    verdicts.append(f\"Consciousness ON added {latency_delta:.1f}s mean latency overhead per prompt\")
elif latency_delta < 0:
    verdicts.append(f\"Consciousness ON was {abs(latency_delta):.1f}s faster per prompt (unexpected)\")

analysis['verdicts'] = verdicts

with open('$OUTPUT', 'w') as f:
    json.dump(analysis, f, indent=2)

print(f'  ✅ Analysis written to $OUTPUT')
print(f'  Verdicts:')
for v in verdicts:
    print(f'    • {v}')
" || echo "  ⚠️  Python analysis failed. Check python3 availability."
