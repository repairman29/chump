#!/usr/bin/env python3.12
"""validate_manipulation.py — Manipulation check for warm-start neuromod/consciousness studies.

Usage:
    scripts/ab-harness/validate_manipulation.py <trials.jsonl> [<fixture.json>] [options]

Options:
    --da-threshold FLOAT   Min DA deviation from 1.0 to count as "fired" (default: 0.05)
    --min-turns INT        Min turns with telemetry to count the trial (default: 2)
    --report               Print per-trial breakdown table
    --exclude-failed       Write a filtered JSONL excluding manipulation failures

The script reads the telemetry_path field from each trial row, loads the per-turn
DA/NA/5HT JSONL written by chump's emit_telemetry(), and checks whether the failure
cascade actually changed neuromodulator state. Trials where DA stayed within the
threshold of baseline (1.0) after 2+ turns are "manipulation failures" — the feature
was enabled but didn't activate, so those trials should be excluded from the study.

Exit codes:
    0  — all trials manipulated correctly (or no filtering needed)
    1  — some manipulation failures found (see --exclude-failed to produce clean JSONL)
    2  — argument error
"""

import json
import sys
import argparse
from pathlib import Path
from typing import Optional


def load_telemetry(path: str) -> list[dict]:
    """Load per-turn neuromod telemetry JSONL. Returns empty list if missing."""
    p = Path(path)
    if not p.exists():
        return []
    rows = []
    for line in p.read_text().splitlines():
        line = line.strip()
        if line:
            try:
                rows.append(json.loads(line))
            except json.JSONDecodeError:
                pass
    return rows


def check_trial(telemetry: list[dict], da_threshold: float, min_turns: int) -> dict:
    """Assess whether neuromod state deviated enough from baseline to count."""
    if len(telemetry) < min_turns:
        return {
            "status": "no_telemetry",
            "turns": len(telemetry),
            "min_da": None,
            "max_da_deviation": None,
            "fired": False,
        }

    da_values = [t["dopamine"] for t in telemetry if "dopamine" in t]
    na_values = [t["noradrenaline"] for t in telemetry if "noradrenaline" in t]
    ht_values = [t["serotonin"] for t in telemetry if "serotonin" in t]

    min_da = min(da_values) if da_values else 1.0
    max_da_deviation = abs(1.0 - min_da)

    # Manipulation is considered "fired" if DA dropped at least da_threshold from baseline.
    # For failure-cascade tasks: 4 failures × ~0.08 DA drop each ≈ 0.32 total drop → min_da ≈ 0.68.
    # For success-cascade tasks: DA should stay near 1.0 (within threshold).
    fired = max_da_deviation >= da_threshold

    return {
        "status": "ok",
        "turns": len(telemetry),
        "min_da": round(min_da, 4),
        "min_na": round(min(na_values), 4) if na_values else None,
        "min_serotonin": round(min(ht_values), 4) if ht_values else None,
        "max_da_deviation": round(max_da_deviation, 4),
        "fired": fired,
    }


def main():
    parser = argparse.ArgumentParser(
        description="Manipulation check for warm-start neuromod/consciousness studies"
    )
    parser.add_argument("trials_jsonl", help="Path to ab-harness trials JSONL")
    parser.add_argument("fixture_json", nargs="?", help="Optional fixture JSON (for category labels)")
    parser.add_argument("--da-threshold", type=float, default=0.05,
                        help="Min DA deviation from 1.0 to count as fired (default: 0.05)")
    parser.add_argument("--min-turns", type=int, default=2,
                        help="Min telemetry turns required to assess a trial (default: 2)")
    parser.add_argument("--report", action="store_true",
                        help="Print per-trial breakdown table")
    parser.add_argument("--exclude-failed", action="store_true",
                        help="Write a filtered JSONL excluding manipulation failures")
    args = parser.parse_args()

    trials_path = Path(args.trials_jsonl)
    if not trials_path.exists():
        print(f"ERROR: {args.trials_jsonl} not found", file=sys.stderr)
        sys.exit(2)

    # Load fixture for category labels (optional).
    fixture_categories: dict[str, str] = {}
    if args.fixture_json:
        fixture_path = Path(args.fixture_json)
        if fixture_path.exists():
            fixture = json.loads(fixture_path.read_text())
            for task in fixture.get("tasks", []):
                fixture_categories[task["id"]] = task.get("category", "unknown")

    # Read trials.
    trials = []
    for line in trials_path.read_text().splitlines():
        line = line.strip()
        if line:
            try:
                trials.append(json.loads(line))
            except json.JSONDecodeError:
                pass

    if not trials:
        print(f"ERROR: no trials found in {args.trials_jsonl}", file=sys.stderr)
        sys.exit(2)

    # Assess each trial.
    results = []
    for trial in trials:
        tpath = trial.get("telemetry_path", "")
        telemetry = load_telemetry(tpath) if tpath else []
        assessment = check_trial(telemetry, args.da_threshold, args.min_turns)
        category = trial.get("category") or fixture_categories.get(trial.get("task_id", ""), "unknown")
        results.append({
            "task_id": trial.get("task_id"),
            "mode": trial.get("mode"),
            "flag_value": trial.get("flag_value"),
            "category": category,
            "telemetry_path": tpath,
            **assessment,
        })

    # Summary stats.
    neuromod_on = [r for r in results if r.get("flag_value") == "1"]
    neuromod_off = [r for r in results if r.get("flag_value") == "0"]

    on_fired = [r for r in neuromod_on if r["fired"]]
    on_no_telem = [r for r in neuromod_on if r["status"] == "no_telemetry"]
    on_failed = [r for r in neuromod_on if not r["fired"]]

    off_no_telem = [r for r in neuromod_off if r["status"] == "no_telemetry"]

    print("=" * 64)
    print("MANIPULATION CHECK REPORT")
    print("=" * 64)
    print(f"Trials file:     {args.trials_jsonl}")
    print(f"DA threshold:    ±{args.da_threshold} from 1.0")
    print(f"Min turns:       {args.min_turns}")
    print()
    print(f"Total trials:    {len(results)}")
    print(f"  NEUROMOD=1:    {len(neuromod_on)}")
    print(f"    Fired:       {len(on_fired)}  ({100*len(on_fired)/max(len(neuromod_on),1):.1f}%)")
    print(f"    No telem:    {len(on_no_telem)}  (neuromod may be disabled or telemetry path missing)")
    print(f"    Did NOT fire:{len(on_failed) - len(on_no_telem)}  (DA stayed within threshold — manipulation failure)")
    print(f"  NEUROMOD=0:    {len(neuromod_off)}")
    print(f"    No telem:    {len(off_no_telem)}  (expected — neuromod off → no telemetry)")
    print()

    # Per-category breakdown for NEUROMOD=1 trials.
    cats: dict[str, dict] = {}
    for r in neuromod_on:
        cat = r["category"]
        if cat not in cats:
            cats[cat] = {"total": 0, "fired": 0, "no_telem": 0}
        cats[cat]["total"] += 1
        if r["fired"]:
            cats[cat]["fired"] += 1
        if r["status"] == "no_telemetry":
            cats[cat]["no_telem"] += 1

    if cats:
        print("Per-category (NEUROMOD=1):")
        print(f"  {'Category':<30} {'Total':>6} {'Fired':>6} {'NoTelm':>7} {'Rate':>6}")
        for cat, s in sorted(cats.items()):
            rate = 100 * s["fired"] / max(s["total"], 1)
            print(f"  {cat:<30} {s['total']:>6} {s['fired']:>6} {s['no_telem']:>7} {rate:>5.1f}%")
        print()

    # Per-trial report.
    if args.report:
        print("Per-trial breakdown (NEUROMOD=1):")
        print(f"  {'task_id':<40} {'mode':>4} {'turns':>6} {'min_da':>7} {'dev':>6} {'fired':>6}")
        for r in sorted(neuromod_on, key=lambda x: x["task_id"]):
            min_da = f"{r['min_da']:.4f}" if r["min_da"] is not None else "  —   "
            dev = f"{r['max_da_deviation']:.4f}" if r["max_da_deviation"] is not None else "  —   "
            fired = "YES" if r["fired"] else ("N/A" if r["status"] == "no_telemetry" else "NO ")
            print(f"  {r['task_id']:<40} {r['mode']:>4} {r['turns']:>6} {min_da:>7} {dev:>6} {fired:>6}")
        print()

    # Produce filtered JSONL if requested.
    if args.exclude_failed:
        # A "passed" trial is: mode B (neuromod off, no manipulation to check) OR
        # mode A (neuromod on) where telemetry fired. Exclude mode A no-telemetry
        # and mode A that didn't fire.
        fired_ids = {(r["task_id"], r["mode"]) for r in on_fired}
        off_ids = {(r["task_id"], r["mode"]) for r in neuromod_off}

        filtered_path = trials_path.with_suffix(".manipulation-passed.jsonl")
        kept = []
        dropped = []
        for trial in trials:
            key = (trial.get("task_id"), trial.get("mode"))
            if key in fired_ids or key in off_ids:
                kept.append(trial)
            else:
                dropped.append(trial)

        filtered_path.write_text("\n".join(json.dumps(t) for t in kept) + "\n")
        print(f"Filtered JSONL: {filtered_path}")
        print(f"  Kept:    {len(kept)} trials")
        print(f"  Dropped: {len(dropped)} trials (manipulation failures)")
        print()

    # Verdict.
    manipulation_failures = [r for r in neuromod_on if not r["fired"] and r["status"] != "no_telemetry"]
    if manipulation_failures:
        print(f"VERDICT: {len(manipulation_failures)} manipulation failure(s) found.")
        print("  These trials should be excluded. Re-run with --exclude-failed to produce a clean JSONL.")
        sys.exit(1)
    elif on_no_telem and not on_fired:
        print("VERDICT: WARNING — no telemetry found for any NEUROMOD=1 trial.")
        print("  Check that CHUMP_NEUROMOD_TELEMETRY_PATH is being exported in run.sh")
        print("  and that CHUMP_NEUROMOD_ENABLED=1 was set during the run.")
        sys.exit(1)
    else:
        print("VERDICT: OK — manipulation check passed.")
        print(f"  {len(on_fired)}/{len(neuromod_on)} NEUROMOD=1 trials showed DA deviation ≥ {args.da_threshold}.")
        sys.exit(0)


if __name__ == "__main__":
    main()
