#!/usr/bin/env bash
# generate-research-draft.sh — Generate a draft research report from A/B study data.
#
# Reads logs/study-analysis.json and produces docs/CONSCIOUSNESS_AB_RESULTS.md.

set -euo pipefail

ROOT="${CHUMP_HOME:-$(cd "$(dirname "$0")/.." && pwd)}"
LOG_DIR="$ROOT/logs"
export ANALYSIS="$LOG_DIR/study-analysis.json"
export OUTPUT="$ROOT/docs/CONSCIOUSNESS_AB_RESULTS.md"

if [[ ! -f "$ANALYSIS" ]]; then
  echo "ERROR: No analysis file found. Run analyze-ab-results.sh first."
  exit 1
fi

echo "  Generating draft research report..."

python3 - <<'EOF'
import json, sys, os
from datetime import datetime

analysis_file = os.environ['ANALYSIS']
output_file = os.environ['OUTPUT']

with open(analysis_file) as f:
    a = json.load(f)

m = a['metrics']
t = a.get('timing', {})
meta_on = a.get('on_metadata', {})
meta_off = a.get('off_metadata', {})
verdicts = a.get('verdicts', [])
prompts = a.get('prompt_comparison', [])

now = datetime.utcnow().strftime('%Y-%m-%d')
model = a.get('model', 'unknown')
hardware = a.get('hardware', 'unknown')
study_id = a.get('study_id', 'unknown')

report = f"""# Consciousness Framework A/B Study Results

> **Study ID:** {study_id}
> **Date:** {now}
> **Status:** DRAFT — requires human review before publication

---

## 1. Methodology

### Hardware & Model
| Parameter | Value |
|-----------|-------|
| Hardware | {hardware} |
| RAM | {meta_on.get('ram_gb', '?')} GB |
| Model | {model} |
| API Base | {meta_on.get('api_base', '?')} |

### Study Design
- **Independent variable:** `CHUMP_CONSCIOUSNESS_ENABLED` (1 = ON, 0 = OFF)
- **Prompt battery:** {len(prompts)} prompts across 7 categories (memory store, tool use, episodes, tasks, reasoning, graph density, edge cases)
- **Control:** Fresh SQLite database for each condition (no data bleed)
- **Measurement:** Structured JSON baselines captured after each battery run

---

## 2. Results

### 2.1 Key Metrics Comparison

| Metric | Consciousness ON | Consciousness OFF | Delta | % Change |
|--------|:---:|:---:|:---:|:---:|
| Prediction count | {m['prediction_count']['on']:.0f} | {m['prediction_count']['off']:.0f} | {m['prediction_count']['delta']:.0f} | {m['prediction_count']['pct_change']}% |
| Mean surprisal | {m['mean_surprisal']['on']:.4f} | {m['mean_surprisal']['off']:.4f} | {m['mean_surprisal']['delta']:.4f} | {m['mean_surprisal']['pct_change']}% |
| High-surprise % | {m['high_surprise_pct']['on']:.1f}% | {m['high_surprise_pct']['off']:.1f}% | {m['high_surprise_pct']['delta']:.1f}% | — |
| Memory graph triples | {m['memory_graph_triples']['on']:.0f} | {m['memory_graph_triples']['off']:.0f} | {m['memory_graph_triples']['delta']:.0f} | {m['memory_graph_triples']['pct_change']}% |
| Unique entities | {m['memory_graph_entities']['on']:.0f} | {m['memory_graph_entities']['off']:.0f} | {m['memory_graph_entities']['delta']:.0f} | {m['memory_graph_entities']['pct_change']}% |
| Causal lessons | {m['causal_lessons']['on']:.0f} | {m['causal_lessons']['off']:.0f} | {m['causal_lessons']['delta']:.0f} | {m['causal_lessons']['pct_change']}% |
| Episodes logged | {m['episodes']['on']:.0f} | {m['episodes']['off']:.0f} | {m['episodes']['delta']:.0f} | {m['episodes']['pct_change']}% |
| Wall time (total) | {m['wall_time']['on']:.0f}s | {m['wall_time']['off']:.0f}s | {m['wall_time']['delta']:.0f}s | {m['wall_time']['pct_change']}% |

### 2.2 Latency Impact

| Metric | ON | OFF | Delta |
|--------|:---:|:---:|:---:|
| Mean response time | {t.get('on_mean_secs', 0):.2f}s | {t.get('off_mean_secs', 0):.2f}s | {t.get('on_mean_secs', 0) - t.get('off_mean_secs', 0):.2f}s |
| Median response time | {t.get('on_median_secs', 0):.2f}s | {t.get('off_median_secs', 0):.2f}s | {t.get('on_median_secs', 0) - t.get('off_median_secs', 0):.2f}s |
| Prompts succeeded | {t.get('on_prompts_ok', 0)}/{t.get('on_prompts_ok', 0) + t.get('on_prompts_fail', 0)} | {t.get('off_prompts_ok', 0)}/{t.get('off_prompts_ok', 0) + t.get('off_prompts_fail', 0)} | — |
| Prompts failed/timeout | {t.get('on_prompts_fail', 0)} | {t.get('off_prompts_fail', 0)} | {t.get('on_prompts_fail', 0) - t.get('off_prompts_fail', 0):+d} |

### 2.3 Per-Prompt Comparison

| Prompt | ON (s) | OFF (s) | Δ (s) | ON Status | OFF Status |
|--------|:---:|:---:|:---:|:---:|:---:|
"""

for p in prompts:
    d = p['on_secs'] - p['off_secs']
    report += f"| {p['prompt']} | {p['on_secs']} | {p['off_secs']} | {d:+d} | {p['on_status']} | {p['off_status']} |\n"

report += """
---

## 3. Key Findings

"""

for i, v in enumerate(verdicts, 1):
    report += f"{i}. {v}\n"

if not verdicts:
    report += "*No automated verdicts — both conditions may have produced identical results (check if consciousness subsystems are wired in the model's code path).*\n"

report += f"""
---

## 4. Interpretation

> **TODO (human):** Write interpretation of results. Consider:
> - Does the consciousness framework produce measurably different behavior?
> - Is the latency overhead acceptable for the additional capabilities?
> - Do the prediction logs show the surprise tracker is actually reducing errors over the session?
> - Are causal lessons being applied in later prompts?

---

## 5. Limitations

1. **Single model, single run** — Results are from one run with {model}. Larger studies should use multiple models, multiple runs, and statistical significance testing.
2. **Prompt battery is synthetic** — The 28 prompts are designed to exercise all subsystems but do not represent natural user interaction patterns.
3. **Fresh DB per condition** — Real-world usage involves accumulated memory. The study measures "from cold start" behavior only.
4. **No semantic quality scoring** — Response quality is not measured (only timing and structural metrics). Future work should include LLM-as-judge evaluation.
5. **Hardware-specific** — Results are specific to {hardware} with {meta_on.get('ram_gb', '?')}GB RAM.

---

## 6. Reproducibility

```bash
# Reproduce this study
cd $(git rev-parse --show-toplevel)
./scripts/run-consciousness-study.sh
```

Environment variables for customization:
- `CHUMP_EXERCISE_MODEL` — override model
- `CHUMP_EXERCISE_TIMEOUT` — per-prompt timeout (default: 240s)
- `CHUMP_STUDY_SKIP_BUILD` — skip cargo build if binary exists

---

## 7. Raw Data

- [`logs/study-ON-baseline.json`](../logs/study-ON-baseline.json) — full ON metrics
- [`logs/study-OFF-baseline.json`](../logs/study-OFF-baseline.json) — full OFF metrics
- [`logs/study-ON-timings.jsonl`](../logs/study-ON-timings.jsonl) — per-prompt timing (ON)
- [`logs/study-OFF-timings.jsonl`](../logs/study-OFF-timings.jsonl) — per-prompt timing (OFF)
- [`logs/study-analysis.json`](../logs/study-analysis.json) — computed deltas

---

*Generated by `scripts/generate-research-draft.sh` — edit before publishing.*
"""

with open(output_file, 'w') as f:
    f.write(report)

print(f"  ✅ Draft report written to {output_file}")
print("  Sections 1-3 and 5-7 are auto-populated.")
print("  Section 4 (Interpretation) needs human writing.")
EOF
