#!/usr/bin/env python3.12
"""RESEARCH-022: Analyze whether injected module state is referenced in agent responses.

Scans eval-025 archive JSONLs for textual signatures of each module's context injection.
Produces a reference-rate × task-type × outcome table and flags mechanistically unsupported
modules (reference rate < 5% in cell A where the module is active).

Usage:
    python3.12 scripts/ab-harness/analyze-module-references.py [--jsonl-dir <path>]
"""

import argparse
import json
import re
import sys
from collections import defaultdict
from pathlib import Path

# ── Module keyword signatures ────────────────────────────────────────────────
# Each module has a list of regex patterns that would appear in agent output
# if the agent is actively referencing the injected module state.
#
# Sources:
#   neuromodulation: src/neuromodulation.rs::context_summary()
#     → "Neuromod: DA={} NA={} 5HT={} (label)"
#   belief_state:   crates/chump-belief-state/src/lib.rs::context_summary()
#     → "Belief state: trajectory={}, freshness={}, ..."
#   surprisal_ema:  src/surprise_tracker.rs (summary string)
#     → "surprisal EMA: {:.3}, total predictions: ..."
#   blackboard:     src/blackboard.rs::broadcast_context()
#     → "Global workspace (high-salience):\n  [source] ..."
#   spawn_lessons:  src/reflection_db.rs::format_lessons_block()
#     → "## Lessons from prior episodes\n..."
#     Note: agents are explicitly told "do not narrate that you are applying them"
#     so direct keyword references are unlikely by design.

MODULE_PATTERNS: dict[str, list[str]] = {
    "neuromodulation": [
        r"[Nn]euromod\b",
        r"\bDA\s*=\s*[\d.]+",
        r"\bNA\s*=\s*[\d.]+",
        r"\b5HT\s*=\s*[\d.]+",
        r"\bdopamine\b",
        r"\bnoradrenaline\b",
        r"\bserotonin\b",
        r"high focus.*reward",
        r"broad exploration mode",
        r"low reward sensitivity",
        r"patient.*multi-step",
        r"impulsive.*prefer quick",
    ],
    "belief_state": [
        r"Belief state:",
        r"trajectory\s*=\s*[\d.]+",
        r"freshness\s*=\s*[\d.]+",
        r"tools_observed\s*=",
        r"epistemic uncertainty",
        r"trajectory confidence",
        r"Least certain:",
    ],
    "surprisal_ema": [
        r"surprisal\s+EMA:",
        r"surprisal\s+ema",
        r"prediction error",
        r"high-surprise",
    ],
    "blackboard": [
        r"Global workspace",
        r"high-salience",
    ],
    "spawn_lessons": [
        r"Lessons from prior episodes",
        r"prior episodes",
        r"lesson.*directive",
        r"directive.*lesson",
    ],
}

# Compiled patterns (case-insensitive for most, case-sensitive where fmt strings are fixed)
COMPILED: dict[str, list[re.Pattern]] = {
    mod: [re.compile(pat, re.IGNORECASE) for pat in pats]
    for mod, pats in MODULE_PATTERNS.items()
}


def references_module(text: str, module: str) -> bool:
    """Return True if text contains any keyword signature for the module."""
    if not text:
        return False
    for pat in COMPILED[module]:
        if pat.search(text):
            return True
    return False


def load_jsonl(path: Path) -> list[dict]:
    rows = []
    with path.open() as f:
        for line in f:
            line = line.strip()
            if line:
                rows.append(json.loads(line))
    return rows


def infer_active_module(filename: str) -> str | None:
    """Infer which module is under test from the filename."""
    fname = filename.lower()
    if "neuromod" in fname:
        return "neuromodulation"
    if "belief" in fname:
        return "belief_state"
    if "surpris" in fname:
        return "surprisal_ema"
    if "blackboard" in fname:
        return "blackboard"
    if "lesson" in fname or "spawn" in fname:
        return "spawn_lessons"
    if "reflection" in fname or "cog016" in fname:
        # cog016 = lessons injection; reflection eval probes all five modules
        return None  # analyze all
    return None


def analyze_file(path: Path) -> dict:
    """
    Returns:
        {
          "file": str,
          "n_total": int,
          "by_cell": {
            "A": { "n": int, "by_module": { module: { "refs": int, "rate": float, "by_cat_outcome": {...} } } },
            "B": ...
          }
        }
    """
    rows = load_jsonl(path)
    active_module = infer_active_module(path.name)
    modules_to_check = list(MODULE_PATTERNS.keys()) if active_module is None else [active_module]

    # Segregate by cell
    by_cell: dict[str, list[dict]] = defaultdict(list)
    for r in rows:
        cell = r.get("cell", "?")
        by_cell[cell].append(r)

    result = {
        "file": path.name,
        "n_total": len(rows),
        "active_module": active_module,
        "by_cell": {},
    }

    for cell, cell_rows in sorted(by_cell.items()):
        cell_result: dict = {"n": len(cell_rows), "by_module": {}}
        for mod in modules_to_check:
            # reference count overall and broken down by (category, outcome)
            refs = 0
            by_cat_outcome: dict[str, dict] = defaultdict(lambda: {"n": 0, "refs": 0})
            for r in cell_rows:
                text = r.get("agent_text_preview", "") or ""
                cat = r.get("category", "unknown")
                outcome = "correct" if r.get("is_correct") else "incorrect"
                key = f"{cat}|{outcome}"
                by_cat_outcome[key]["n"] += 1
                if references_module(text, mod):
                    refs += 1
                    by_cat_outcome[key]["refs"] += 1

            n = len(cell_rows)
            rate = refs / n if n > 0 else 0.0
            cell_result["by_module"][mod] = {
                "n": n,
                "refs": refs,
                "rate": rate,
                "by_cat_outcome": {
                    k: {
                        "n": v["n"],
                        "refs": v["refs"],
                        "rate": v["refs"] / v["n"] if v["n"] > 0 else 0.0,
                    }
                    for k, v in sorted(by_cat_outcome.items())
                },
            }
        result["by_cell"][cell] = cell_result

    return result


def render_markdown(analyses: list[dict]) -> str:
    lines = [
        "# RESEARCH-022: Module Reference-Rate Analysis",
        "",
        "Scans `agent_text_preview` fields in eval-025 archive JSONLs for textual",
        "signatures of each module's context injection. A reference means the agent",
        "explicitly cited or echoed module-injected text in its response.",
        "",
        "**Decision rule:** any module with reference rate < 5% in cell A (module ON)",
        "is flagged as mechanistically unsupported — injected state is not influencing",
        "visible reasoning.",
        "",
    ]

    for analysis in analyses:
        fname = analysis["file"]
        active = analysis["active_module"] or "all"
        n_total = analysis["n_total"]
        lines.append(f"## {fname}")
        lines.append(f"*n={n_total} rows total, active module under test: `{active}`*")
        lines.append("")

        for cell in sorted(analysis["by_cell"].keys()):
            cell_data = analysis["by_cell"][cell]
            n_cell = cell_data["n"]
            lines.append(f"### Cell {cell} (n={n_cell})")
            lines.append("")

            # Summary table header
            lines.append("| Module | Refs | N | Rate | Mechanistic support |")
            lines.append("|--------|------|---|------|---------------------|")
            for mod, stats in sorted(cell_data["by_module"].items()):
                rate = stats["rate"]
                flag = ""
                if cell == "A" and rate < 0.05:
                    flag = " **UNSUPPORTED**"
                lines.append(
                    f"| {mod} | {stats['refs']} | {stats['n']} | {rate:.1%}{flag} | {'✗ <5%' if cell == 'A' and rate < 0.05 else '✓' if rate >= 0.05 else '—'} |"
                )
            lines.append("")

            # Per-module breakdown by category × outcome
            for mod, stats in sorted(cell_data["by_module"].items()):
                if not stats["by_cat_outcome"]:
                    continue
                lines.append(f"**{mod}** breakdown (cell {cell}):")
                lines.append("")
                lines.append("| Category | Outcome | Refs | N | Rate |")
                lines.append("|----------|---------|------|---|------|")
                for key, v in sorted(stats["by_cat_outcome"].items()):
                    cat, outcome = key.split("|", 1)
                    lines.append(f"| {cat} | {outcome} | {v['refs']} | {v['n']} | {v['rate']:.1%} |")
                lines.append("")

    # Overall flags section
    lines.append("## Flags: Mechanistically Unsupported Modules (cell A rate < 5%)")
    lines.append("")
    any_flag = False
    for analysis in analyses:
        if "A" not in analysis["by_cell"]:
            continue
        cell_a = analysis["by_cell"]["A"]
        active = analysis["active_module"]
        if active is None:
            continue  # skip multi-module files for per-file flags
        stats = cell_a["by_module"].get(active, {})
        rate = stats.get("rate", 0.0)
        if rate < 0.05:
            lines.append(
                f"- **{active}** in `{analysis['file']}`: "
                f"{stats.get('refs', 0)}/{stats.get('n', 0)} = {rate:.1%} — "
                "injected state not visible in agent reasoning"
            )
            any_flag = True
    if not any_flag:
        lines.append("*(none — all active modules exceed 5% reference rate in cell A)*")
    lines.append("")

    return "\n".join(lines)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--jsonl-dir",
        default="docs/archive/eval-runs/eval-025-cog016-validation",
        help="Directory containing eval JSONL files",
    )
    parser.add_argument(
        "--output",
        default="docs/eval/RESEARCH-022-module-reference-analysis.md",
        help="Output markdown file",
    )
    parser.add_argument(
        "--json-output",
        default=None,
        help="Optional JSON output for machine consumption",
    )
    args = parser.parse_args()

    jsonl_dir = Path(args.jsonl_dir)
    if not jsonl_dir.exists():
        print(f"ERROR: JSONL dir not found: {jsonl_dir}", file=sys.stderr)
        sys.exit(1)

    jsonl_files = sorted(jsonl_dir.glob("*.jsonl"))
    if not jsonl_files:
        print(f"ERROR: no .jsonl files in {jsonl_dir}", file=sys.stderr)
        sys.exit(1)

    print(f"Analyzing {len(jsonl_files)} JSONL files in {jsonl_dir}...")

    analyses = []
    for path in jsonl_files:
        print(f"  {path.name} ...", end=" ")
        analysis = analyze_file(path)
        analyses.append(analysis)
        n = analysis["n_total"]
        active = analysis["active_module"] or "all"
        print(f"n={n}, module={active}")

    # Write markdown
    md = render_markdown(analyses)
    output_path = Path(args.output)
    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_text(md)
    print(f"\nWrote: {output_path}")

    # Optional JSON
    if args.json_output:
        Path(args.json_output).write_text(json.dumps(analyses, indent=2))
        print(f"Wrote JSON: {args.json_output}")

    # Exit non-zero if any unsupported modules found
    flags = []
    for analysis in analyses:
        if "A" not in analysis["by_cell"]:
            continue
        active = analysis["active_module"]
        if active is None:
            continue
        stats = analysis["by_cell"]["A"]["by_module"].get(active, {})
        rate = stats.get("rate", 0.0)
        if rate < 0.05:
            flags.append(f"{active} ({analysis['file']}): {rate:.1%}")

    if flags:
        print("\nFLAGGED (mechanistically unsupported):")
        for f in flags:
            print(f"  - {f}")
        print("\nNote: these modules have <5% reference rate in cell A.")
        print("This is consistent with injection not influencing visible reasoning.")
        sys.exit(2)  # non-zero but distinct from error (1)

    print("\nAll active modules exceed 5% reference rate in cell A.")
    sys.exit(0)


if __name__ == "__main__":
    main()
