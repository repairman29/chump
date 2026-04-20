#!/usr/bin/env python3
"""EVAL-041/EVAL-046: compute Cohen's kappa between human grades and LLM judge scores.

Reads docs/eval/EVAL-010-labels-jeff.md (Jeff's human grades) and computes:
  - Per-fixture Cohen's kappa (human vs LLM judge)
  - Agreement percentage per fixture
  - Verdict: does any fixture fail the 0.75 kappa threshold?
  - JSON summary written to docs/eval/EVAL-010-kappa-results.json

Cohen's kappa measures inter-rater agreement corrected for chance agreement.
  kappa = (P_o - P_e) / (1 - P_e)
  where P_o = observed agreement rate, P_e = expected agreement by chance.

Thresholds (Landis & Koch 1977):
  < 0.20  — slight
  0.20–0.40 — fair
  0.40–0.60 — moderate
  0.60–0.75 — substantial
  >= 0.75   — almost perfect (our publication threshold)

Usage:
    python3 scripts/eval-human-label/compute-kappa.py
    python3 scripts/eval-human-label/compute-kappa.py --input docs/eval/EVAL-010-labels-jeff.md
    python3 scripts/eval-human-label/compute-kappa.py --json-out docs/eval/EVAL-010-kappa-results.json

EVAL-046 calibration workflow (run after completing EVAL-010-labels-jeff.md):

  Step 1 — Establish v1 baseline kappa with full 42-task dataset:
    python3 scripts/eval-human-label/compute-kappa.py \\
        --input docs/eval/EVAL-010-labels-jeff.md \\
        --json-out docs/eval/EVAL-010-kappa-v1-full.json

  Step 2 — Re-run harness on the same 42 tasks using the v2 judge prompt:
    python3 scripts/ab-harness/run-cloud-v2.py \\
        --fixture scripts/ab-harness/fixtures/reflection_tasks.json \\
        --tag reflection-haiku45-v2judge \\
        --model claude-haiku-4-5 \\
        --judge claude-sonnet-4-5 \\
        --judge-system-version v2 \\
        --limit 14
    # (repeat for perception_tasks.json and neuromod_tasks.json)

  Step 3 — Update EVAL-010-labels-jeff.md with v2 judge scores from the new run,
    then recompute kappa:
    python3 scripts/eval-human-label/compute-kappa.py \\
        --input docs/eval/EVAL-010-labels-jeff.md \\
        --json-out docs/eval/EVAL-010-kappa-v2-full.json

  Step 4 — Compare v1 vs v2 kappa per fixture. Any fixture still failing kappa < 0.75
    with v2 judge should switch to human grading only before citing eval deltas.
    See docs/eval/EVAL-046-judge-calibration.md for the full decision protocol.
"""
from __future__ import annotations

import argparse
import json
import re
import sys
from collections import defaultdict
from pathlib import Path


# --- Markdown parsing ---

TASK_HEAD = re.compile(r"^###\s+`([^`]+)`\s+\(([^)]+)\)\s*$")
GRADE_LINE = re.compile(r"^- Human grade (A|B): \[(.)\] PASS\s*$")
LLM_SCORE_LINE = re.compile(r"\*\(LLM judge:\s+([\d.]+)\)\*")
SOURCE_LINE = re.compile(r"^## Fixture:\s+(\S+)")


def parse_labels(md_path: Path) -> dict[str, dict[str, dict]]:
    """Parse human grades and LLM judge scores from a labels markdown file.

    Returns:
        {fixture_name: {task_id: {
            "category": str,
            "A_human": bool | None,   # True=pass, False=fail, None=pending
            "B_human": bool | None,
            "A_llm": float | None,    # raw LLM judge score (0.0–1.0)
            "B_llm": float | None,
        }}}
    """
    out: dict[str, dict[str, dict]] = defaultdict(dict)
    current_fixture: str | None = None
    current_task: str | None = None
    current_cat: str | None = None
    current_mode: str | None = None

    for raw in md_path.read_text().splitlines():
        line = raw.strip()

        m = SOURCE_LINE.match(line)
        if m:
            current_fixture = m.group(1)
            continue

        m = TASK_HEAD.match(line)
        if m:
            current_task = m.group(1)
            current_cat = m.group(2)
            if current_fixture and current_task not in out[current_fixture]:
                out[current_fixture][current_task] = {
                    "category": current_cat,
                    "A_human": None,
                    "B_human": None,
                    "A_llm": None,
                    "B_llm": None,
                }
            continue

        # Track which mode (A or B) we're currently in for LLM score extraction
        if "**Mode A**" in line:
            current_mode = "A"
        elif "**Mode B**" in line:
            current_mode = "B"

        # Extract LLM judge score from the mode header line
        m = LLM_SCORE_LINE.search(line)
        if m and current_fixture and current_task and current_mode:
            score_str = m.group(1)
            try:
                score = float(score_str)
                task_rec = out[current_fixture].get(current_task)
                if task_rec is not None:
                    task_rec[f"{current_mode}_llm"] = score
            except ValueError:
                pass

        # Extract human grade
        m = GRADE_LINE.match(line)
        if m and current_fixture and current_task:
            mode = m.group(1)
            mark = m.group(2).strip().lower()
            task_rec = out[current_fixture].get(current_task)
            if task_rec is None:
                continue
            if mark == "x":
                task_rec[f"{mode}_human"] = True
            elif mark == "-":
                task_rec[f"{mode}_human"] = False
            # blank = pending, leave None

    return out


def cohen_kappa(ratings_1: list[bool], ratings_2: list[bool]) -> float:
    """Compute Cohen's kappa for two binary raters over the same items.

    Both lists must have the same length. Items where either rater is None
    should be filtered out before calling this function.
    """
    n = len(ratings_1)
    if n == 0:
        return float("nan")

    agree = sum(a == b for a, b in zip(ratings_1, ratings_2))
    p_o = agree / n

    # Expected agreement by chance
    p1_pos = sum(ratings_1) / n
    p2_pos = sum(ratings_2) / n
    p_e = p1_pos * p2_pos + (1 - p1_pos) * (1 - p2_pos)

    if p_e >= 1.0:
        return 1.0  # Perfect agreement on trivially all-same data

    kappa = (p_o - p_e) / (1 - p_e)
    return kappa


KAPPA_THRESHOLD = 0.75


def main() -> int:
    ap = argparse.ArgumentParser(description="Compute Cohen's kappa for EVAL-010 human labels.")
    ap.add_argument(
        "--input",
        default="docs/eval/EVAL-010-labels-jeff.md",
        help="Path to Jeff's labels markdown file",
    )
    ap.add_argument(
        "--json-out",
        default="docs/eval/EVAL-010-kappa-results.json",
        help="Path to write JSON summary",
    )
    ap.add_argument("--quiet", action="store_true", help="Suppress human-readable output")
    args = ap.parse_args()

    md = Path(args.input)
    if not md.exists():
        print(f"error: {md} not found.", file=sys.stderr)
        return 2

    labels = parse_labels(md)
    if not labels:
        print(f"error: no graded labels found in {md}", file=sys.stderr)
        return 3

    summary: dict[str, dict] = {}
    any_fails_threshold = False
    total_labeled = 0
    total_pending = 0

    if not args.quiet:
        print(f"\n=== EVAL-010 — Cohen's kappa: human vs LLM judge ===")
        print(f"Threshold: kappa >= {KAPPA_THRESHOLD} (Landis & Koch 'almost perfect')\n")

    for fixture_name in ("reflection", "perception", "neuromod"):
        task_grades = labels.get(fixture_name, {})
        if not task_grades:
            if not args.quiet:
                print(f"--- {fixture_name} --- (no data)\n")
            continue

        human_ratings: list[bool] = []
        llm_ratings: list[bool] = []
        pending_count = 0
        labeled_count = 0
        disagreements: list[str] = []

        for tid, rec in task_grades.items():
            for mode in ("A", "B"):
                h = rec.get(f"{mode}_human")
                l_score = rec.get(f"{mode}_llm")

                if h is None:
                    pending_count += 1
                    continue

                labeled_count += 1

                if l_score is None:
                    # No LLM score available — can't compare, but count the human grade
                    continue

                l_pass = l_score >= 0.5
                human_ratings.append(h)
                llm_ratings.append(l_pass)

                if h != l_pass:
                    disagreements.append(f"{tid} mode {mode}: human={'PASS' if h else 'FAIL'} llm={'PASS' if l_pass else 'FAIL'} (score={l_score:.2f})")

        total_labeled += labeled_count
        total_pending += pending_count

        n_comparable = len(human_ratings)
        kappa = cohen_kappa(human_ratings, llm_ratings) if n_comparable >= 2 else float("nan")
        agree_pct = (sum(h == l for h, l in zip(human_ratings, llm_ratings)) / n_comparable * 100) if n_comparable else float("nan")

        passes_threshold = (not (kappa != kappa)) and kappa >= KAPPA_THRESHOLD  # NaN-safe
        if not passes_threshold and n_comparable >= 4:
            any_fails_threshold = True

        status = "PASS" if passes_threshold else ("INSUFFICIENT DATA" if n_comparable < 4 else "FAIL")

        summary[fixture_name] = {
            "labeled_pairs": labeled_count,
            "pending_pairs": pending_count,
            "comparable_pairs": n_comparable,
            "kappa": round(kappa, 4) if kappa == kappa else None,
            "agreement_pct": round(agree_pct, 1) if agree_pct == agree_pct else None,
            "threshold": KAPPA_THRESHOLD,
            "passes_threshold": passes_threshold,
            "status": status,
            "disagreements": disagreements,
        }

        if not args.quiet:
            kappa_str = f"{kappa:.3f}" if kappa == kappa else "N/A"
            agree_str = f"{agree_pct:.1f}%" if agree_pct == agree_pct else "N/A"
            print(f"--- {fixture_name} ---")
            print(f"  labeled pairs:    {labeled_count} (A+B)")
            print(f"  pending pairs:    {pending_count} (not yet graded)")
            print(f"  comparable pairs: {n_comparable} (have both human + LLM score)")
            print(f"  agreement:        {agree_str}")
            print(f"  Cohen's kappa:    {kappa_str}")
            print(f"  threshold (0.75): {status}")
            if disagreements:
                print(f"  disagreements ({len(disagreements)}):")
                for d in disagreements[:5]:
                    print(f"    {d}")
                if len(disagreements) > 5:
                    print(f"    ... and {len(disagreements) - 5} more")
            print()

    overall_summary = {
        "total_labeled_pairs": total_labeled,
        "total_pending_pairs": total_pending,
        "total_task_pairs": total_labeled + total_pending,
        "kappa_threshold": KAPPA_THRESHOLD,
        "any_fixture_fails_threshold": any_fails_threshold,
        "fixtures": summary,
        "note": "Preliminary — n=12 labeled tasks, 30 pending human review (EVAL-041)",
    }

    json_out = Path(args.json_out)
    json_out.parent.mkdir(parents=True, exist_ok=True)
    json_out.write_text(json.dumps(overall_summary, indent=2))

    if not args.quiet:
        print(f"=== Overall ===")
        print(f"  Total labeled pairs: {total_labeled}")
        print(f"  Total pending:       {total_pending}")
        print(f"  JSON results:        {json_out}")
        print()

        print("=== Verdict ===")
        if any_fails_threshold:
            print("  FAIL: One or more fixtures have kappa < 0.75.")
            print("  The LLM-as-judge methodology for those fixtures is unreliable.")
            print("  Action: Complete pending human grades, then file a follow-on gap")
            print("  to either recalibrate the judge or switch to human grading for")
            print("  the affected fixture.")
        else:
            print("  PASS (preliminary): All fixtures with sufficient data meet kappa >= 0.75.")
            print("  Complete the remaining 30 pending pairs to confirm.")
        print()
        print("  NOTE: Results are preliminary with n=12 labeled tasks.")
        print("  Complete all 42 tasks before citing kappa in research claims.")

    return 0 if not any_fails_threshold else 1


if __name__ == "__main__":
    sys.exit(main())
