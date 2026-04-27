#!/usr/bin/env bash
# populate-paper-section4.sh — Write real data into section 4 of the research paper.
#
# Reads the most recent logs/study/multi-model-*.json (produced by
# run-multi-model-study.sh) and overwrites section 4 of
# docs/research/consciousness-framework-paper.md with live tables.
#
# Run automatically at the end of run-multi-model-study.sh, or manually:
#   scripts/setup/populate-paper-section4.sh
#   scripts/setup/populate-paper-section4.sh logs/study/multi-model-1234.json

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PAPER="$ROOT/docs/research/consciousness-framework-paper.md"

RESULTS_JSON="${1:-}"
if [[ -z "$RESULTS_JSON" ]]; then
  RESULTS_JSON=$(ls -t "$ROOT/logs/study/multi-model-"*.json 2>/dev/null | head -1 || true)
fi

if [[ -z "$RESULTS_JSON" || ! -f "$RESULTS_JSON" ]]; then
  echo "ERROR: No multi-model results JSON found. Run run-multi-model-study.sh first." >&2
  exit 1
fi

echo "  populating section 4 from $RESULTS_JSON"

python3 - "$RESULTS_JSON" "$PAPER" <<'PY'
import json, sys, re
from pathlib import Path
from datetime import datetime, timezone

results_path = Path(sys.argv[1])
paper_path = Path(sys.argv[2])

results = json.loads(results_path.read_text())
models = results.get("models", [])
generated_at = results.get("generated_at", "unknown")
fixture = results.get("fixture", "unknown")
limit = results.get("limit", "?")

now = datetime.now(timezone.utc).strftime("%Y-%m-%d")
judge_info = ""
for m in models:
    jm = m.get("judge_model") or m.get("by_mode", {}).get("A", {}).get("judge_model")
    ja = m.get("judge_api", "ollama")
    if jm:
        judge_info = f"{jm} (via {ja})"
        break

def pct(v):
    if v is None:
        return "—"
    return f"{v * 100:.1f}%"

def fmt_delta(d):
    if d is None:
        return "—"
    sign = "+" if d >= 0 else ""
    return f"{sign}{d * 100:.1f}pp"

# Build the section 4 markdown.
lines = [
    "## 4. Results [AUTO]",
    "",
    f"> Auto-generated {now} from `{results_path.name}` · fixture: `{Path(fixture).name}` · {limit} tasks/model",
    "",
]

if not models:
    lines += ["> No model data found.", ""]
else:
    # Judge info row.
    if judge_info:
        lines += [f"> **Judge:** {judge_info}", ""]

    # 4.1 Pass-rate table (A=ON, B=OFF, delta).
    lines += [
        "### 4.1 Consciousness ON vs OFF — Pass Rate by Model",
        "",
        "| Model | ON (A) | OFF (B) | Delta (A−B) | Mean Judge Score (ON) | Mean Judge Score (OFF) |",
        "|-------|:------:|:-------:|:-----------:|:---------------------:|:----------------------:|",
    ]
    for m in models:
        tag = m.get("tag", "?")
        # Extract model name from tag (e.g. "study-qwen2-5-7b-reflection" → "qwen2.5:7b")
        model_name = tag.replace("study-", "").replace("-reflection", "")
        # Reverse the colon/dot mangling: llama3-2-1b → llama3.2:1b
        model_name = re.sub(r"(\d+)-(\d+)-(\w+b)$", r"\1.\2:\3", model_name)
        model_name = model_name.replace("-", ":")
        bm = m.get("by_mode", {})
        a = bm.get("A", {})
        b = bm.get("B", {})
        a_rate = pct(a.get("rate"))
        b_rate = pct(b.get("rate"))
        delta = fmt_delta(m.get("delta"))
        a_judge = f"{a.get('mean_judge_score', 0):.2f}" if "mean_judge_score" in a else "—"
        b_judge = f"{b.get('mean_judge_score', 0):.2f}" if "mean_judge_score" in b else "—"
        lines.append(f"| {model_name} | {a_rate} | {b_rate} | {delta} | {a_judge} | {b_judge} |")
    lines.append("")

    # 4.2 Latency table.
    lines += [
        "### 4.2 Latency Overhead by Model Size",
        "",
        "| Model | Trials | Avg Duration A (ms) | Avg Duration B (ms) | Latency Delta |",
        "|-------|:------:|:-------------------:|:-------------------:|:-------------:|",
    ]
    for m in models:
        tag = m.get("tag", "?")
        model_name = tag.replace("study-", "").replace("-reflection", "")
        model_name = re.sub(r"(\d+)-(\d+)-(\w+b)$", r"\1.\2:\3", model_name)
        model_name = model_name.replace("-", ":")
        tc = m.get("trial_count", "?")
        bm = m.get("by_mode", {})
        a_dur = bm.get("A", {}).get("avg_duration_ms")
        b_dur = bm.get("B", {}).get("avg_duration_ms")
        if a_dur and b_dur:
            a_s = f"{a_dur:,.0f}"
            b_s = f"{b_dur:,.0f}"
            diff = a_dur - b_dur
            sign = "+" if diff >= 0 else ""
            lat_delta = f"{sign}{diff:,.0f}ms"
        else:
            a_s = b_s = lat_delta = "—"
        lines.append(f"| {model_name} | {tc} | {a_s} | {b_s} | {lat_delta} |")
    lines.append("")

    # 4.3 Per-category breakdown for first model.
    first = models[0]
    by_cat = first.get("by_category", {})
    if by_cat:
        tag = first.get("tag", "?")
        model_name = tag.replace("study-", "").replace("-reflection", "")
        model_name = re.sub(r"(\d+)-(\d+)-(\w+b)$", r"\1.\2:\3", model_name)
        model_name = model_name.replace("-", ":")
        lines += [
            f"### 4.3 Category Breakdown — {model_name}",
            "",
            "| Category | ON Pass% | OFF Pass% | Delta |",
            "|----------|:--------:|:---------:|:-----:|",
        ]
        for cat, modes in sorted(by_cat.items()):
            a_r = modes.get("A", {}).get("rate")
            b_r = modes.get("B", {}).get("rate")
            d = round(a_r - b_r, 3) if (a_r is not None and b_r is not None) else None
            lines.append(f"| {cat} | {pct(a_r)} | {pct(b_r)} | {fmt_delta(d)} |")
        lines.append("")

    lines += [
        "### 4.4 Summary",
        "",
        "| Metric | Value |",
        "|--------|-------|",
        f"| Models tested | {len(models)} |",
        f"| Tasks per model | {limit} |",
        f"| Fixture | {Path(fixture).name} |",
        f"| Judge | {judge_info or 'structural only'} |",
        f"| Generated | {now} |",
        "",
    ]

lines.append("---")
section4_md = "\n".join(lines)

# Splice into the paper: replace from "## 4. Results" up to (not including) "## 5.".
paper_text = paper_path.read_text()
new_text = re.sub(
    r"## 4\. Results \[AUTO\].*?(?=^## 5\.)",
    section4_md + "\n\n",
    paper_text,
    flags=re.DOTALL | re.MULTILINE,
)
if new_text == paper_text:
    print("  WARNING: section 4 pattern not found — appending instead")
    new_text = paper_text.rstrip() + "\n\n" + section4_md + "\n"

paper_path.write_text(new_text)
print(f"  wrote section 4 → {paper_path}")
PY
