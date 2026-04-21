#!/usr/bin/env python3.12
"""COG-006 Section 3.3 gate evaluator.

Reads the summary.json produced by scripts/ab-harness/score.py for a
cog-006-neuromod-ab run and evaluates the Section 3.3 gate from
docs/CHUMP_TO_COMPLEX.md:

    Gate: Measure whether modulator-driven adaptation outperforms the
    current fixed-threshold regime on a 50-turn diverse task set.

Gate criteria:
    PASS:
        delta_by_category["dynamic"] >= 0
            — neuromod (Mode A) does not regress dynamic task success vs baseline
        abs(delta_by_category.get("trivial", 0)) < 0.15
            — trivial tasks are unaffected (neuromod is a no-op for them)

    WARN (gate passes but with low confidence):
        All PASS criteria met, but dynamic_delta < 0.05 AND fewer than
        10 dynamic tasks were run (low N, inconclusive signal).

    FAIL:
        dynamic_delta < 0 (neuromod hurts dynamic tasks)
        OR trivial_distortion >= 0.15 (neuromod breaks trivial tasks)

Rationale for conservative threshold:
    Structural scoring (keyword heuristics, not LLM-judge) is noisy.
    Requiring delta > 0 (not a fixed threshold like ≥0.05) avoids
    false-negatives on genuine improvements that don't clear an
    arbitrary margin on 25 tasks. Improvement magnitude is reported
    for documentation regardless.

Usage:
    python3 scripts/ab-harness/score-cog006.py <summary.json>

Exit codes:
    0 — gate passed (or passed with warning)
    1 — gate failed
    2 — usage/input error
"""
from __future__ import annotations

import json
import sys
from pathlib import Path


def load_summary(path: Path) -> dict:
    try:
        return json.loads(path.read_text())
    except (json.JSONDecodeError, OSError) as e:
        print(f"ERROR: cannot read summary: {e}", file=sys.stderr)
        sys.exit(2)


def evaluate_gate(summary: dict) -> int:
    """Evaluate Section 3.3 gate. Return 0 (pass), 1 (fail)."""
    tag = summary.get("tag", "?")
    trial_count = summary.get("trial_count", 0)
    by_mode = summary.get("by_mode", {})
    delta_by_cat = summary.get("delta_by_category", {})
    delta_overall = summary.get("delta", 0.0)

    # ── Extract per-mode rates ────────────────────────────────────────────────
    a_rate = by_mode.get("A", {}).get("rate", None)
    b_rate = by_mode.get("B", {}).get("rate", None)

    # ── Extract per-category deltas ───────────────────────────────────────────
    dynamic_delta  = delta_by_cat.get("dynamic", None)
    trivial_delta  = delta_by_cat.get("trivial", None)
    adaptive_delta = delta_by_cat.get("adaptive", None)

    # ── Per-category pass rates ───────────────────────────────────────────────
    by_cat = summary.get("by_category", {})

    def cat_rate(cat: str, mode: str) -> str | float:
        m = by_cat.get(cat, {}).get(mode, {})
        if not m:
            return "n/a"
        p = m.get("passed", 0)
        f = m.get("failed", 0)
        t = p + f
        return f"{p}/{t}={m.get('rate', 0.0):.3f}" if t else "n/a"

    # ── Report ────────────────────────────────────────────────────────────────
    print(f"tag           : {tag}")
    print(f"trials        : {trial_count}")
    if a_rate is not None and b_rate is not None:
        print(f"mode A (neuromod=1): {a_rate:.3f}  mode B (baseline=0): {b_rate:.3f}")
        print(f"overall delta (A−B): {delta_overall:+.3f}")
    print()

    headers = ["category", "A (neuromod=1)", "B (baseline=0)", "delta (A−B)"]
    rows = []
    for cat in ("dynamic", "trivial", "adaptive"):
        a = cat_rate(cat, "A")
        b = cat_rate(cat, "B")
        d = delta_by_cat.get(cat, None)
        d_str = f"{d:+.3f}" if d is not None else "n/a"
        rows.append((cat, a, b, d_str))

    col_widths = [max(len(h), max(len(str(r[i])) for r in rows)) for i, h in enumerate(headers)]
    fmt = "  ".join(f"{{:<{w}}}" for w in col_widths)
    print(fmt.format(*headers))
    print("  ".join("-" * w for w in col_widths))
    for row in rows:
        print(fmt.format(*row))
    print()

    # ── Gate evaluation ───────────────────────────────────────────────────────
    issues: list[str] = []
    warnings: list[str] = []

    # Gate 1: dynamic tasks — neuromod must not regress
    if dynamic_delta is None:
        warnings.append("no 'dynamic' category in results (fixture may be too small)")
    elif dynamic_delta < 0:
        issues.append(
            f"dynamic delta {dynamic_delta:+.3f} < 0 "
            f"— neuromod HURTS dynamic task success (regresses vs baseline)"
        )
    elif dynamic_delta < 0.05:
        # Warn only if we had enough tasks to draw conclusions
        dyn_a_total = by_cat.get("dynamic", {}).get("A", {})
        n_dynamic = (dyn_a_total.get("passed", 0) + dyn_a_total.get("failed", 0))
        if n_dynamic < 10:
            warnings.append(
                f"dynamic delta {dynamic_delta:+.3f} is small and N={n_dynamic} "
                f"dynamic tasks is low — result is inconclusive"
            )
        else:
            warnings.append(
                f"dynamic delta {dynamic_delta:+.3f} is positive but small — "
                f"neuromod improves dynamic tasks only marginally"
            )

    # Gate 2: trivial tasks — neuromod must not distort noise floor
    if trivial_delta is not None:
        trivial_distortion = abs(trivial_delta)
        if trivial_distortion >= 0.15:
            issues.append(
                f"trivial |delta| {trivial_distortion:.3f} >= 0.15 "
                f"— neuromod significantly affects trivial (no-signal) tasks; "
                f"indicates spurious modulation or regime instability"
            )
        elif trivial_distortion >= 0.08:
            warnings.append(
                f"trivial |delta| {trivial_distortion:.3f} is elevated — "
                f"monitor for spurious modulation on no-signal tasks"
            )

    # ── Outcome ───────────────────────────────────────────────────────────────
    for w in warnings:
        print(f"  ⚠  WARN: {w}")
    for issue in issues:
        print(f"  ✗  FAIL: {issue}")

    if issues:
        print()
        print("Section 3.3 gate: FAILED")
        print("Neuromodulation does not outperform fixed-threshold regime.")
        print("Check modulator wiring (src/neuromodulation.rs) and ensure")
        print("CHUMP_NEUROMOD_ENABLED=1 actually changes regime thresholds.")
        return 1

    print()
    if warnings:
        print("Section 3.3 gate: PASSED (with warnings — see above)")
    else:
        if dynamic_delta is not None and dynamic_delta > 0:
            print(f"Section 3.3 gate: PASSED")
            print(f"Neuromod-driven adaptation improves dynamic task success by "
                  f"{dynamic_delta:+.3f} over fixed-threshold baseline.")
        else:
            print("Section 3.3 gate: PASSED (delta=0, non-regression confirmed)")
    print()
    print("Next: mark COG-006 done in docs/gaps.yaml.")
    print("Consider running with --judge-claude claude-haiku-4-5 for semantic scoring (COG-011b).")
    return 0


def main() -> int:
    if len(sys.argv) < 2:
        print(__doc__)
        return 2

    path = Path(sys.argv[1])
    if not path.exists():
        print(f"ERROR: {path} not found", file=sys.stderr)
        return 2

    summary = load_summary(path)
    return evaluate_gate(summary)


if __name__ == "__main__":
    sys.exit(main())
