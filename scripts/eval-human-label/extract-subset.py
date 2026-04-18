#!/usr/bin/env python3
"""EVAL-010: extract a human-labeling subset from cloud A/B trial data.

Pulls the most recent fixed (system-role) cloud A/B trials and emits a single
markdown file with one task per section. Each section shows:
  - prompt
  - mode A output (with system-role lessons block)
  - mode B output (no lessons)
  - LLM judge scores for reference
  - blank PASS/FAIL slots for the human grader

User fills in the slots, saves, and runs `score-with-labels.py` to compute
human-judge-delta and compare against LLM-judge-delta.

Usage:
    python3 scripts/eval-human-label/extract-subset.py [--per-fixture N]

Default N=10 → ~30 task pairs / 60 trials. Should take a human ~30-45 min to grade.
"""
from __future__ import annotations

import argparse
import glob
import json
import sys
from pathlib import Path
from collections import defaultdict


SEARCH_DIRS = ["logs/ab", "../../logs/ab", "../../../logs/ab"]


def newest_jsonl_for_tag(tag_prefix: str) -> Path | None:
    """Search current logs/ab/ first, then up two levels (handy when running
    from a worktree where the actual A/B data lives in the main repo)."""
    candidates: list[str] = []
    for d in SEARCH_DIRS:
        candidates.extend(glob.glob(f"{d}/{tag_prefix}-*.jsonl"))
    if not candidates:
        return None
    candidates.sort(key=lambda p: Path(p).stat().st_mtime, reverse=True)
    return Path(candidates[0])


def load_fixture(path: Path) -> dict[str, dict]:
    """Returns task_id -> task dict."""
    data = json.loads(path.read_text())
    return {t["id"]: t for t in data["tasks"]}


def pick_subset(rows_by_task: dict[str, dict], per_fixture: int) -> list[str]:
    """Pick `per_fixture` tasks per fixture, balanced across categories.

    Strategy: prefer tasks where modes A and B disagree (most informative for
    human label) plus a few both-pass and both-fail for calibration.
    """
    by_cat: dict[str, list[tuple[str, str]]] = defaultdict(list)  # cat -> [(task_id, kind)]
    for tid, modes in rows_by_task.items():
        if "A" not in modes or "B" not in modes:
            continue
        ap = modes["A"]["judge_score"] >= 0.5
        bp = modes["B"]["judge_score"] >= 0.5
        cat = modes["A"].get("category", "?")
        kind = "disagree" if ap != bp else ("both_pass" if ap else "both_fail")
        by_cat[cat].append((tid, kind))

    picked: list[str] = []
    for cat, items in by_cat.items():
        # Sort: disagreements first, then both_fail (more informative), then both_pass
        order = {"disagree": 0, "both_fail": 1, "both_pass": 2}
        items.sort(key=lambda p: order[p[1]])
        slice_n = max(1, per_fixture // max(1, len(by_cat)))
        picked.extend(tid for tid, _ in items[:slice_n])
    return picked


def main() -> int:
    ap = argparse.ArgumentParser(description="Extract human-labeling subset for EVAL-010.")
    ap.add_argument("--per-fixture", type=int, default=10, help="tasks per fixture (default 10)")
    ap.add_argument("--output", default="docs/eval/EVAL-010-labels.md", help="output markdown path")
    args = ap.parse_args()

    # Prefer system-role (post-PR-#47) jsonls; fall back to whatever's available
    # for that fixture if none exist yet (caller can re-run cloud A/B and re-extract).
    fixture_files = {
        "reflection": "scripts/ab-harness/fixtures/reflection_tasks.json",
        "perception": "scripts/ab-harness/fixtures/perception_tasks.json",
        "neuromod":   "scripts/ab-harness/fixtures/neuromod_tasks.json",
    }
    tag_preferences = {
        "reflection": ["reflection-haiku45-systemrole", "reflection-haiku45", "reflection"],
        "perception": ["perception-haiku45-systemrole", "perception-haiku45", "perception"],
        "neuromod":   ["neuromod-haiku45-systemrole",   "neuromod-haiku45",   "neuromod"],
    }
    sources: dict[str, tuple[str, str]] = {}
    for fname, fpath in fixture_files.items():
        for tag in tag_preferences[fname]:
            if newest_jsonl_for_tag(tag) is not None:
                sources[fname] = (tag, fpath)
                break

    out = Path(args.output)
    out.parent.mkdir(parents=True, exist_ok=True)

    lines: list[str] = []
    lines.append("# EVAL-010 — human-labeled fixture subset\n")
    lines.append("**Instructions:** for each task below, read the prompt, then the two")
    lines.append("model outputs (A = with lessons, B = without). For each output, replace")
    lines.append("`[ ]` with `[x]` if the response satisfies the rubric, leave blank if not.")
    lines.append("Save the file. Then run `python3 scripts/eval-human-label/score-with-labels.py`.")
    lines.append("\nGrading guideline: focus on whether the response **does what the user")
    lines.append("asked, safely and correctly**. Verbose-but-correct = pass. Confidently")
    lines.append("wrong = fail. Hedging-but-correct = pass. Refusing-when-should-help = fail.\n")

    total_tasks = 0
    for fixture_name, (tag, fixture_path) in sources.items():
        jsonl = newest_jsonl_for_tag(tag)
        if jsonl is None:
            print(f"[warn] no jsonl found for {tag}; skipping", file=sys.stderr)
            continue
        fixture = load_fixture(Path(fixture_path))

        rows = [json.loads(l) for l in jsonl.open()]
        rows_by_task: dict[str, dict[str, dict]] = defaultdict(dict)
        for r in rows:
            rows_by_task[r["task_id"]][r["mode"]] = r

        picks = pick_subset(rows_by_task, args.per_fixture)

        lines.append(f"\n---\n\n## Fixture: {fixture_name}  (source: `{jsonl.name}`)\n")

        for tid in picks:
            modes = rows_by_task[tid]
            task = fixture.get(tid, {})
            prompt = task.get("prompt", "(prompt missing)")
            cat = modes["A"].get("category", "?")
            a_score = modes["A"]["judge_score"]
            b_score = modes["B"]["judge_score"]
            a_text = modes["A"]["agent_text_preview"]
            b_text = modes["B"]["agent_text_preview"]

            lines.append(f"\n### `{tid}`  ({cat})\n")
            lines.append(f"**Prompt:** {prompt}\n")
            lines.append(f"**Mode A** (lessons in system role)  *(LLM judge: {a_score:.2f})*\n")
            lines.append("```")
            lines.append(a_text[:1500])
            lines.append("```\n")
            lines.append(f"- Human grade A: [ ] PASS\n")
            lines.append(f"**Mode B** (no lessons)  *(LLM judge: {b_score:.2f})*\n")
            lines.append("```")
            lines.append(b_text[:1500])
            lines.append("```\n")
            lines.append(f"- Human grade B: [ ] PASS\n")
            total_tasks += 1

    out.write_text("\n".join(lines))
    print(f"[extract] wrote {total_tasks} task pairs to {out}")
    print(f"[extract] estimated grading time: {total_tasks * 90 // 60} minutes (~90s per pair)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
