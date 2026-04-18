#!/usr/bin/env python3
"""
analyze-neuromod-telemetry.py — CLI tool for inspecting neuromodulation telemetry logs.

Usage:
    python scripts/analyze-neuromod-telemetry.py [TELEMETRY_FILE] [--compare OTHER_FILE]

Arguments:
    TELEMETRY_FILE   Path to a neuromod-telemetry-*.jsonl file.
                     If omitted, globs for the latest logs/neuromod-telemetry-*.jsonl.

Options:
    --compare OTHER  Path to a second JSONL file for side-by-side mean comparison.

Output:
    1. ASCII trajectory table (turn-by-turn DA / NA / 5HT with a human label)
    2. Sparklines for each modulator across all turns
    3. Per-modulator summary stats (mean, min, max, std, low/high zone turn counts)
    4. NA-drop analysis: turns where NA < 0.8 and distance to recovery (NA >= 1.0)
    5. (--compare) Side-by-side mean DA / NA / 5HT comparison between two files

Telemetry line format (one JSON object per line):
    {"turn": N, "dopamine": X.XXXX, "noradrenaline": X.XXXX, "serotonin": X.XXXX, "ts_ms": T}

Environment variable CHUMP_NEUROMOD_TELEMETRY_PATH is also checked as a fallback
if neither argv[1] nor any glob match is found.
"""

import json
import math
import os
import glob
import sys
from typing import Optional


# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

BLOCKS = " ▁▂▃▄▅▆▇█"
LOW_ZONE = 0.7    # below this: "low / impulsive"
HIGH_ZONE = 1.3   # above this: "high / focused"
NA_DROP_THRESH = 0.8    # "exploration mode" threshold
NA_RECOVER_THRESH = 1.0  # "recovery" threshold


# ---------------------------------------------------------------------------
# I/O helpers
# ---------------------------------------------------------------------------

def find_latest_telemetry() -> Optional[str]:
    env_path = os.environ.get("CHUMP_NEUROMOD_TELEMETRY_PATH")
    if env_path and os.path.isfile(env_path):
        return env_path
    candidates = sorted(glob.glob("logs/neuromod-telemetry-*.jsonl"))
    return candidates[-1] if candidates else None


def load_jsonl(path: str) -> list[dict]:
    records = []
    with open(path) as fh:
        for lineno, raw in enumerate(fh, 1):
            raw = raw.strip()
            if not raw:
                continue
            try:
                records.append(json.loads(raw))
            except json.JSONDecodeError as exc:
                print(f"  [warn] line {lineno}: {exc}", file=sys.stderr)
    if not records:
        sys.exit(f"error: no valid records found in {path!r}")
    records.sort(key=lambda r: r.get("turn", 0))
    return records


# ---------------------------------------------------------------------------
# Stats helpers
# ---------------------------------------------------------------------------

def mean(vals: list[float]) -> float:
    return sum(vals) / len(vals) if vals else 0.0


def std(vals: list[float]) -> float:
    if len(vals) < 2:
        return 0.0
    m = mean(vals)
    return math.sqrt(sum((v - m) ** 2 for v in vals) / len(vals))


def sparkline(vals: list[float]) -> str:
    lo, hi = min(vals), max(vals)
    span = hi - lo or 1.0
    chars = []
    for v in vals:
        idx = int((v - lo) / span * (len(BLOCKS) - 1))
        chars.append(BLOCKS[idx])
    return "".join(chars)


def label_turn(da: float, na: float, ht: float) -> str:
    tags = []
    if da < LOW_ZONE:
        tags.append("DA-low")
    elif da > HIGH_ZONE:
        tags.append("DA-high")
    if na < LOW_ZONE:
        tags.append("NA-low")
    elif na > HIGH_ZONE:
        tags.append("NA-high")
    if ht < LOW_ZONE:
        tags.append("5HT-low")
    elif ht > HIGH_ZONE:
        tags.append("5HT-high")
    if not tags:
        all_near = all(abs(v - 1.0) < 0.1 for v in (da, na, ht))
        return "near baseline" if all_near else "nominal"
    return ", ".join(tags)


# ---------------------------------------------------------------------------
# Report sections
# ---------------------------------------------------------------------------

def print_trajectory(records: list[dict]) -> None:
    print("\n=== Turn-by-turn trajectory ===\n")
    print(f"{'Turn':>5}  {'DA':>6}  {'NA':>6}  {'5HT':>6}  Summary")
    print(f"{'----':>5}  {'----':>6}  {'----':>6}  {'----':>6}  -------")
    for r in records:
        turn = r.get("turn", "?")
        da = r.get("dopamine", 0.0)
        na = r.get("noradrenaline", 0.0)
        ht = r.get("serotonin", 0.0)
        lbl = label_turn(da, na, ht)
        print(f"{turn:>5}  {da:>6.4f}  {na:>6.4f}  {ht:>6.4f}  {lbl}")


def print_sparklines(records: list[dict]) -> None:
    da_vals = [r.get("dopamine", 0.0) for r in records]
    na_vals = [r.get("noradrenaline", 0.0) for r in records]
    ht_vals = [r.get("serotonin", 0.0) for r in records]
    print("\n=== Sparklines (low ← → high within each series) ===\n")
    print(f"  DA : {sparkline(da_vals)}")
    print(f"  NA : {sparkline(na_vals)}")
    print(f" 5HT : {sparkline(ht_vals)}")


def print_stats(records: list[dict]) -> None:
    print("\n=== Per-modulator summary stats ===\n")
    header = f"  {'Mod':>4}  {'Mean':>7}  {'Min':>7}  {'Max':>7}  {'Std':>7}  {'<0.7':>5}  {'>1.3':>5}"
    print(header)
    print("  " + "-" * (len(header) - 2))
    for key, label in [("dopamine", "DA"), ("noradrenaline", "NA"), ("serotonin", "5HT")]:
        vals = [r.get(key, 0.0) for r in records]
        low_count = sum(1 for v in vals if v < LOW_ZONE)
        high_count = sum(1 for v in vals if v > HIGH_ZONE)
        print(
            f"  {label:>4}  {mean(vals):>7.4f}  {min(vals):>7.4f}  {max(vals):>7.4f}"
            f"  {std(vals):>7.4f}  {low_count:>5}  {high_count:>5}"
        )


def print_na_drop_analysis(records: list[dict]) -> None:
    print("\n=== NA-drop analysis (exploration mode) ===\n")
    print(f"  Drops: NA < {NA_DROP_THRESH}  |  Recovery: NA >= {NA_RECOVER_THRESH}\n")
    na_vals = [(r.get("turn", i), r.get("noradrenaline", 0.0)) for i, r in enumerate(records)]

    drops_found = False
    i = 0
    while i < len(na_vals):
        turn, na = na_vals[i]
        if na < NA_DROP_THRESH:
            drops_found = True
            # find recovery
            recovery_dist = None
            for j in range(i + 1, len(na_vals)):
                if na_vals[j][1] >= NA_RECOVER_THRESH:
                    recovery_dist = na_vals[j][0] - turn
                    break
            if recovery_dist is not None:
                print(f"  Turn {turn:>4}: NA={na:.4f}  -> recovery in {recovery_dist} turn(s)")
            else:
                print(f"  Turn {turn:>4}: NA={na:.4f}  -> no recovery observed in remaining turns")
            # skip ahead past contiguous drop
            while i < len(na_vals) and na_vals[i][1] < NA_DROP_THRESH:
                i += 1
        else:
            i += 1

    if not drops_found:
        print(f"  No turns with NA < {NA_DROP_THRESH} found.")


def print_comparison(path_a: str, path_b: str) -> None:
    print("\n=== File comparison (mean DA / NA / 5HT) ===\n")
    recs_a = load_jsonl(path_a)
    recs_b = load_jsonl(path_b)

    def means(recs):
        return {
            "DA":  mean([r.get("dopamine", 0.0) for r in recs]),
            "NA":  mean([r.get("noradrenaline", 0.0) for r in recs]),
            "5HT": mean([r.get("serotonin", 0.0) for r in recs]),
        }

    ma, mb = means(recs_a), means(recs_b)
    label_a = os.path.basename(path_a)
    label_b = os.path.basename(path_b)
    col = max(len(label_a), len(label_b), 20)

    print(f"  {'Mod':>4}  {label_a:<{col}}  {label_b:<{col}}  Delta")
    print("  " + "-" * (4 + 2 + col + 2 + col + 2 + 8))
    for mod in ("DA", "NA", "5HT"):
        delta = mb[mod] - ma[mod]
        sign = "+" if delta >= 0 else ""
        print(f"  {mod:>4}  {ma[mod]:<{col}.4f}  {mb[mod]:<{col}.4f}  {sign}{delta:.4f}")
    print(f"\n  Turns: {label_a}: {len(recs_a)}   {label_b}: {len(recs_b)}")


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

def main() -> None:
    args = sys.argv[1:]
    if not args or args[0] in ("-h", "--help"):
        print("Usage: analyze-neuromod-telemetry.py [telemetry.jsonl] [--compare other.jsonl]")
        print("  Reads CHUMP_NEUROMOD_TELEMETRY_PATH JSONL and prints DA/NA/5HT trajectory,")
        print("  sparklines, summary stats, and NA-drop analysis.")
        print("  With no argument, globs for logs/neuromod-telemetry-*.jsonl.")
        sys.exit(0)
    compare_path: Optional[str] = None

    # Parse --compare
    if "--compare" in args:
        idx = args.index("--compare")
        if idx + 1 >= len(args):
            sys.exit("error: --compare requires a second file path argument")
        compare_path = args[idx + 1]
        args = args[:idx] + args[idx + 2:]

    # Primary file
    if args:
        primary_path = args[0]
    else:
        primary_path = find_latest_telemetry()
        if not primary_path:
            sys.exit(
                "error: no telemetry file given and no logs/neuromod-telemetry-*.jsonl found.\n"
                "Set CHUMP_NEUROMOD_TELEMETRY_PATH or pass a path as argv[1]."
            )

    print(f"Loading: {primary_path}")
    records = load_jsonl(primary_path)
    print(f"  {len(records)} turns loaded.")

    print_trajectory(records)
    print_sparklines(records)
    print_stats(records)
    print_na_drop_analysis(records)

    if compare_path:
        print(f"\nComparing against: {compare_path}")
        print_comparison(primary_path, compare_path)

    print()


if __name__ == "__main__":
    main()
