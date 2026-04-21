#!/usr/bin/env python3.12
"""rescore-with-v2.py — apply v2 multi-axis scoring to existing v1 jsonl.

Useful when you have v1 A/B output (from run.sh against local Ollama, or
the older run-cloud.py) and want the v2 multi-axis breakdown without
spending more API budget. Re-uses the LLM judge_score that's already in
the jsonl; the hallucination check is a cheap regex on agent_text_preview.

Outputs a -rescored.summary.json next to the input jsonl. Existing files
are not modified.

Usage:
    python3 scripts/ab-harness/rescore-with-v2.py path/to/run.jsonl
    python3 scripts/ab-harness/rescore-with-v2.py path/to/run.jsonl --threshold 0.5
"""
from __future__ import annotations

import argparse
import json
import sys
from collections import defaultdict
from pathlib import Path

# Add scoring_v2 to path
sys.path.insert(0, str(Path(__file__).parent))
from scoring_v2 import score_trial, delta_significance, wilson_ci  # noqa: E402


def normalize_cell(row: dict) -> str:
    """Map v1 'mode' or v2 'cell' to canonical A/B."""
    return row.get("cell") or row.get("mode") or "A"


def normalize_text(row: dict) -> str:
    """Find the agent text across our various harness schemas:
      - cloud v1/v2 harness: agent_text_preview
      - local run.sh harness (chump-backed): final_text_preview
      - other variants: agent_text or output fallback
    """
    return (
        row.get("agent_text_preview")
        or row.get("final_text_preview")
        or row.get("agent_text")
        or row.get("output")
        or ""
    )


def normalize_score(row: dict) -> float:
    """Find judge score across our schemas:
      - cloud v1/v2: judge_score (numeric)
      - local run.sh: success (bool) — convert to 1.0/0.0 since the
        local harness scores via a separate post-hoc step
    """
    if "judge_score" in row:
        return float(row["judge_score"])
    if "success" in row:
        return 1.0 if row["success"] else 0.0
    return 0.0


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("jsonl_path", help="Path to v1 (or v2) jsonl from any harness")
    ap.add_argument("--threshold", type=float, default=0.5,
                    help="Judge threshold for is_correct (default 0.5)")
    args = ap.parse_args()

    p = Path(args.jsonl_path)
    if not p.exists():
        print(f"error: {p} not found", file=sys.stderr)
        return 2

    rows: list[dict] = []
    with p.open() as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            r = json.loads(line)
            cell = normalize_cell(r)
            text = normalize_text(r)
            score = normalize_score(r)
            ts_ = score_trial(text, score, args.threshold)
            rows.append({
                "task_id": r.get("task_id", "?"),
                "category": r.get("category", "?"),
                "cell": cell,
                "judge_score": score,
                "did_attempt": ts_.did_attempt,
                "hallucinated_tools": ts_.hallucinated_tools,
                "is_correct": ts_.is_correct,
                "agent_text_preview": text[:200],
            })

    by_cell: dict[str, dict] = {}
    for cell in ("A", "B"):
        cell_rows = [r for r in rows if r["cell"] == cell]
        n = len(cell_rows)
        if n == 0:
            continue
        n_correct = sum(1 for r in cell_rows if r["is_correct"])
        n_attempt = sum(1 for r in cell_rows if r["did_attempt"])
        n_halluc = sum(1 for r in cell_rows if r["hallucinated_tools"])
        by_cell[cell] = {
            "n": n,
            "is_correct": {"passes": n_correct, "rate": n_correct / n,
                           "ci_95": list(wilson_ci(n_correct, n))},
            "did_attempt": {"passes": n_attempt, "rate": n_attempt / n,
                            "ci_95": list(wilson_ci(n_attempt, n))},
            "hallucinated_tools": {"count": n_halluc, "rate": n_halluc / n,
                                   "ci_95": list(wilson_ci(n_halluc, n))},
            "mean_judge_score": sum(r["judge_score"] for r in cell_rows) / n,
        }

    a_n = by_cell.get("A", {}).get("n", 0)
    b_n = by_cell.get("B", {}).get("n", 0)
    deltas = {}
    if a_n and b_n:
        deltas = {
            "is_correct": delta_significance(
                by_cell["A"]["is_correct"]["passes"], a_n,
                by_cell["B"]["is_correct"]["passes"], b_n,
            ),
            "did_attempt": delta_significance(
                by_cell["A"]["did_attempt"]["passes"], a_n,
                by_cell["B"]["did_attempt"]["passes"], b_n,
            ),
            "hallucinated_tools": delta_significance(
                by_cell["A"]["hallucinated_tools"]["count"], a_n,
                by_cell["B"]["hallucinated_tools"]["count"], b_n,
            ),
        }

    summary = {
        "rescored_from": str(p),
        "harness_version": "v1-rescored-as-v2",
        "trial_count": a_n + b_n,
        "by_cell": by_cell,
        "deltas": deltas,
    }

    out_path = p.with_name(p.stem + ".rescored.summary.json")
    out_path.write_text(json.dumps(summary, indent=2))

    print(f"=== Rescored {p.name} (n={a_n}/{b_n}) ===")
    for cell in ("A", "B"):
        if cell not in by_cell:
            continue
        c = by_cell[cell]
        print(f"  {cell}: correct={c['is_correct']['rate']:.2f} "
              f"[{c['is_correct']['ci_95'][0]:.2f},{c['is_correct']['ci_95'][1]:.2f}]  "
              f"halluc={c['hallucinated_tools']['rate']:.2f}  "
              f"attempt={c['did_attempt']['rate']:.2f}")
    print()
    for axis, dx in deltas.items():
        marker = " ⚠️ WITHIN NOISE" if dx["cis_overlap"] else " ✓ provisional signal"
        print(f"  Δ {axis:20s}: {dx['delta']:+.3f}{marker}")
    print(f"\nwrote {out_path}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
