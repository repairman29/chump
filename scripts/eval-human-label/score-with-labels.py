#!/usr/bin/env python3
"""EVAL-010: score human-graded labels and compare against LLM judge.

Reads docs/eval/EVAL-010-labels.md (output of extract-subset.py with the
human grader's [x] marks filled in) and produces:
  - Human-judge delta per fixture
  - LLM-judge delta per fixture (pulled from the same source jsonl)
  - Per-fixture agreement rate (% of trials where human and LLM agree)
  - Verdict: if any fixture's human-vs-LLM delta gap exceeds 0.05, recommend
    deprecating LLM-as-judge for that fixture class.

Usage:
    python3 scripts/eval-human-label/score-with-labels.py \\
        [--input docs/eval/EVAL-010-labels.md]
"""
from __future__ import annotations

import argparse
import json
import re
import sys
import glob
from collections import defaultdict
from pathlib import Path


# Markdown task block: ### `task_id`  (category)
TASK_HEAD = re.compile(r"^###\s+`([^`]+)`\s+\(([^)]+)\)\s*$")
GRADE_LINE = re.compile(r"^- Human grade (A|B): \[(.)\] PASS\s*$")
SOURCE_LINE = re.compile(r"^## Fixture:\s+(\S+)\s+\(source:\s+`([^`]+)`")


def parse_labels(md_path: Path) -> dict[str, dict[str, dict[str, bool | str]]]:
    """Returns {fixture: {task_id: {"A": True/False, "B": True/False, "category": cat}}}.

    Convention: [x] = pass, [-] = explicit fail, [ ] = ungraded (skipped).
    Distinguishing fail from ungraded matters: a blank box might mean the
    grader hasn't gotten to it yet, vs. they reviewed it and judged it failed.
    """
    out: dict[str, dict[str, dict]] = defaultdict(dict)
    current_fixture: str | None = None
    current_task: str | None = None
    current_cat: str | None = None
    for raw in md_path.read_text().splitlines():
        m = SOURCE_LINE.match(raw.strip())
        if m:
            current_fixture = m.group(1)
            continue
        m = TASK_HEAD.match(raw.strip())
        if m:
            current_task = m.group(1)
            current_cat = m.group(2)
            continue
        m = GRADE_LINE.match(raw.strip())
        if m and current_fixture and current_task:
            mode = m.group(1)
            mark = m.group(2).strip().lower()
            if mark == "x":
                graded_pass: bool = True
            elif mark == "-":
                graded_pass = False
            else:
                continue  # blank → not yet graded
            out[current_fixture].setdefault(current_task, {"category": current_cat})[mode] = graded_pass
    return out


SEARCH_DIRS = ["logs/ab", "../../logs/ab", "../../../logs/ab"]


def newest_jsonl_for_tag(tag_prefix: str) -> Path | None:
    candidates: list[str] = []
    for d in SEARCH_DIRS:
        candidates.extend(glob.glob(f"{d}/{tag_prefix}-*.jsonl"))
    if not candidates:
        return None
    candidates.sort(key=lambda p: Path(p).stat().st_mtime, reverse=True)
    return Path(candidates[0])


def llm_scores_for(fixture_name: str) -> dict[str, dict[str, bool]]:
    """Pull LLM judge pass/fail for the same fixture from the most recent
    cloud A/B jsonl. Returns {task_id: {"A": pass, "B": pass}}."""
    for tag in (f"{fixture_name}-haiku45-systemrole", f"{fixture_name}-haiku45", fixture_name):
        jsonl = newest_jsonl_for_tag(tag)
        if jsonl is not None:
            break
    else:
        return {}
    out: dict[str, dict[str, bool]] = {}
    for line in jsonl.open():
        r = json.loads(line)
        out.setdefault(r["task_id"], {})[r["mode"]] = bool(r["scored"])
    return out


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--input", default="docs/eval/EVAL-010-labels.md")
    args = ap.parse_args()

    md = Path(args.input)
    if not md.exists():
        print(f"error: {md} not found. Run extract-subset.py first.", file=sys.stderr)
        return 2

    labels = parse_labels(md)
    if not labels:
        print(f"error: no graded labels found in {md}. Did you fill in [x] marks?", file=sys.stderr)
        return 3

    print(f"\n=== EVAL-010 — human vs LLM judge agreement ===\n")
    grand_disagreements: list[tuple[str, str]] = []
    for fixture_name, task_grades in labels.items():
        llm = llm_scores_for(fixture_name)
        a_pass = b_pass = a_total = b_total = 0
        agree = total = 0
        for tid, grades in task_grades.items():
            for mode in ("A", "B"):
                if mode not in grades:
                    continue
                hp = grades[mode]
                if mode == "A":
                    a_total += 1
                    if hp:
                        a_pass += 1
                else:
                    b_total += 1
                    if hp:
                        b_pass += 1
                if tid in llm and mode in llm[tid]:
                    total += 1
                    if hp == llm[tid][mode]:
                        agree += 1
                    else:
                        grand_disagreements.append((fixture_name, f"{tid} mode {mode}: human={hp} llm={llm[tid][mode]}"))

        if a_total == 0 or b_total == 0:
            print(f"{fixture_name}: insufficient grades (A={a_total}, B={b_total}); skipping")
            continue

        a_rate = a_pass / a_total
        b_rate = b_pass / b_total
        human_delta = a_rate - b_rate
        agreement_pct = (agree / total * 100) if total else 0.0

        # LLM delta from the same task subset
        llm_a_pass = llm_b_pass = llm_a_total = llm_b_total = 0
        for tid in task_grades:
            if tid in llm:
                if "A" in llm[tid]:
                    llm_a_total += 1
                    llm_a_pass += int(llm[tid]["A"])
                if "B" in llm[tid]:
                    llm_b_total += 1
                    llm_b_pass += int(llm[tid]["B"])
        llm_delta = (llm_a_pass / llm_a_total - llm_b_pass / llm_b_total) if (llm_a_total and llm_b_total) else 0.0

        gap = abs(human_delta - llm_delta)
        gap_marker = " ⚠️ DISAGREEMENT" if gap > 0.05 else ""

        print(f"--- {fixture_name} ---")
        print(f"  graded:        {a_total} A trials, {b_total} B trials")
        print(f"  human  delta:  A={a_rate:.2f} B={b_rate:.2f} → Δ={human_delta:+.3f}")
        print(f"  LLM    delta:  A={llm_a_pass/llm_a_total:.2f} B={llm_b_pass/llm_b_total:.2f} → Δ={llm_delta:+.3f}")
        print(f"  gap |human − LLM|: {gap:.3f}{gap_marker}")
        print(f"  per-trial agreement: {agreement_pct:.1f}%  ({agree}/{total})")
        print()

    if grand_disagreements:
        print(f"=== Disagreement detail ({len(grand_disagreements)} trials) ===")
        for fixture, detail in grand_disagreements[:20]:
            print(f"  [{fixture}] {detail}")
        if len(grand_disagreements) > 20:
            print(f"  ... and {len(grand_disagreements) - 20} more")

    print("\n=== Verdict ===")
    print("If any fixture's |human − LLM| gap > 0.05, the LLM-as-judge methodology")
    print("for that fixture class should be deprecated until calibrated against")
    print("a larger human-labeled set. Update docs/archive/2026-04/briefs/CONSCIOUSNESS_AB_RESULTS.md")
    print("with the human-judge results before any further A/B effort.")

    return 0


if __name__ == "__main__":
    sys.exit(main())
