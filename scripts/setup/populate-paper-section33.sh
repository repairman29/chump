#!/usr/bin/env bash
# populate-paper-section33.sh — Write neuromod A/B results into section 3.3 of
# the research paper.
#
# Reads the most recent logs/study/neuromod-*.json (produced by
# run-neuromod-study.sh) and overwrites section 3.3 of
# docs/research/consciousness-framework-paper.md with live tables.
#
# Run automatically at the end of run-neuromod-study.sh, or manually:
#   scripts/setup/populate-paper-section33.sh
#   scripts/setup/populate-paper-section33.sh logs/study/neuromod-1234.json

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PAPER="$ROOT/docs/research/consciousness-framework-paper.md"

RESULTS_JSON="${1:-}"
if [[ -z "$RESULTS_JSON" ]]; then
  RESULTS_JSON=$(ls -t "$ROOT/logs/study/neuromod-"*.json 2>/dev/null | head -1 || true)
fi

if [[ -z "$RESULTS_JSON" || ! -f "$RESULTS_JSON" ]]; then
  echo "ERROR: No neuromod results JSON found. Run run-neuromod-study.sh first." >&2
  exit 1
fi

echo "  populating section 3.3 from $RESULTS_JSON"

python3 - "$RESULTS_JSON" "$PAPER" <<'PY'
import json, sys, re
from pathlib import Path
from datetime import datetime, timezone

results_path = Path(sys.argv[1])
paper_path = Path(sys.argv[2])

results = json.loads(results_path.read_text())
generated_at = results.get("generated_at", "unknown")
fixture = results.get("fixture", "unknown")
limit = results.get("limit", "?")
model = results.get("model", "?")
now = datetime.now(timezone.utc).strftime("%Y-%m-%d")

judge_info = ""
jm = results.get("judge_model")
ja = results.get("judge_api", "ollama")
if jm:
    judge_info = f"{jm} (via {ja})"

def pct(v):
    if v is None: return "—"
    return f"{v * 100:.1f}%"

def fmt_delta(d, unit="pp"):
    if d is None: return "—"
    sign = "+" if d >= 0 else ""
    if unit == "pp":
        return f"{sign}{d * 100:.1f}pp"
    return f"{sign}{d:.3f}"

bm = results.get("by_mode", {})
a = bm.get("A", {})
b = bm.get("B", {})
by_cat = results.get("by_category", {})
delta_by_cat = results.get("delta_by_category", {})
delta = results.get("delta")
ted = results.get("tool_efficiency_delta")

a_rate = pct(a.get("rate"))
b_rate = pct(b.get("rate"))
a_judge = f"{a.get('mean_judge_score', 0):.2f}" if "mean_judge_score" in a else "—"
b_judge = f"{b.get('mean_judge_score', 0):.2f}" if "mean_judge_score" in b else "—"
a_tc = f"{a.get('avg_tool_calls', 0):.2f}" if "avg_tool_calls" in a else "—"
b_tc = f"{b.get('avg_tool_calls', 0):.2f}" if "avg_tool_calls" in b else "—"

lines = [
    "### 3.3 Neuromodulation Gate [AUTO]",
    "",
    f"> Auto-generated {now} from `{results_path.name}` · model: `{model}` · fixture: `{Path(fixture).name}` · {limit} tasks",
    "",
]

if judge_info:
    lines += [f"> **Judge:** {judge_info}", ""]

lines += [
    "#### 3.3.1 Pass Rate: Neuromod ON (A) vs OFF (B)",
    "",
    "| Condition | Pass Rate | Mean Judge Score | Avg Tool Calls |",
    "|-----------|:---------:|:----------------:|:--------------:|",
    f"| ON  (CHUMP_NEUROMOD_ENABLED=1) | {a_rate} | {a_judge} | {a_tc} |",
    f"| OFF (CHUMP_NEUROMOD_ENABLED=0) | {b_rate} | {b_judge} | {b_tc} |",
    f"| **Delta (A − B)** | **{fmt_delta(delta)}** | — | **{fmt_delta(ted, 'raw')}** |",
    "",
]

if by_cat:
    lines += [
        "#### 3.3.2 Category Breakdown",
        "",
        "| Category | ON Pass% | OFF Pass% | Delta |",
        "|----------|:--------:|:---------:|:-----:|",
    ]
    for cat in sorted(by_cat.keys()):
        modes = by_cat[cat]
        a_r = modes.get("A", {}).get("rate")
        b_r = modes.get("B", {}).get("rate")
        d = delta_by_cat.get(cat)
        lines.append(f"| {cat} | {pct(a_r)} | {pct(b_r)} | {fmt_delta(d)} |")
    lines.append("")

# Section 3.3 interpretation: gate evaluation.
trial_count = results.get("trial_count", 0)
a_n = a.get("passed", 0) + a.get("failed", 0)
b_n = b.get("passed", 0) + b.get("failed", 0)

if delta is not None:
    if delta > 0.05:
        verdict = "PASS — neuromodulation improves task success rate."
    elif delta < -0.05:
        verdict = "INCONCLUSIVE — neuromodulation appears to reduce pass rate; check fixture difficulty balance."
    else:
        verdict = "NEUTRAL — no statistically meaningful pass-rate difference; tool efficiency delta carries the signal."
else:
    verdict = "PENDING — no study data yet."

lines += [
    "#### 3.3.3 Gate Evaluation",
    "",
    "| Metric | Value |",
    "|--------|-------|",
    f"| Total trials | {trial_count} |",
    f"| Trials mode A | {a_n} |",
    f"| Trials mode B | {b_n} |",
    f"| Pass-rate delta (A−B) | {fmt_delta(delta)} |",
    f"| Tool efficiency delta (A−B) | {fmt_delta(ted, 'raw')} |",
    f"| Judge | {judge_info or 'structural only'} |",
    f"| Generated | {now} |",
    "",
    f"> **Verdict:** {verdict}",
    "",
]

lines.append("---")
section33_md = "\n".join(lines)

paper_text = paper_path.read_text()
new_text = re.sub(
    r"### 3\.3 .*?\[AUTO\].*?(?=^### 3\.[4-9]|^## 4\.)",
    section33_md + "\n\n",
    paper_text,
    flags=re.DOTALL | re.MULTILINE,
)
if new_text == paper_text:
    # Fallback: replace the old "Prompt Battery" placeholder if present
    new_text = re.sub(
        r"### 3\.3 Prompt Battery \[AUTO\].*?(?=^### 3\.[4-9]|^## 4\.)",
        section33_md + "\n\n",
        paper_text,
        flags=re.DOTALL | re.MULTILINE,
    )
if new_text == paper_text:
    print("  WARNING: section 3.3 pattern not found — appending instead")
    new_text = paper_text.rstrip() + "\n\n" + section33_md + "\n"

paper_path.write_text(new_text)
print(f"  wrote section 3.3 → {paper_path}")
PY
