#!/usr/bin/env python3.12
"""
RESEARCH-023 — Counterfactual mediation analysis (Pearl 2001 / VanderWeele 2015).

Upgrades A/B module-contribution claims from average-treatment-effect (ATE)
to natural-direct-effect (NDE) + natural-indirect-effect (NIE) causal estimates.

Inputs: one or more trial JSONL files with columns (cell, outcome, mediator).
Outputs: TE, NDE, NIE, proportion-mediated per (mediator, outcome) pair with
bootstrap 95% CIs.

Preregistration: docs/eval/preregistered/RESEARCH-023.md
See docs/eval/RESEARCH-023-mediation-analysis.md for applied results.

References:
- Pearl J. 2001. "Direct and indirect effects." UAI.
- VanderWeele TJ. 2015. "Explanation in Causal Inference." Oxford UP.

Usage:
    # Self-test with synthetic data where NDE/NIE are known
    python3.12 scripts/ab-harness/mediation-analysis.py --self-test

    # Apply to an eval JSONL
    python3.12 scripts/ab-harness/mediation-analysis.py \\
        --jsonl path/to/eval.jsonl \\
        --exposure cell \\
        --exposure-treatment A --exposure-control B \\
        --mediator category \\
        --outcome is_correct \\
        --n-bootstrap 10000 \\
        --seed 42 \\
        --out results.json
"""

from __future__ import annotations

import argparse
import json
import random
import statistics
import sys
from collections import defaultdict
from pathlib import Path


# ---------------------------------------------------------------------------
# Core estimators
# ---------------------------------------------------------------------------


def compute_effects(
    rows: list[dict],
    exposure_col: str,
    exposure_treatment: str,
    exposure_control: str,
    mediator_col: str,
    outcome_col: str,
) -> dict:
    """Compute TE, NDE, NIE on a single (bootstrap-resampled or full) row set.

    Assumptions (standard for mediation analysis):
      1. No unmeasured confounders between exposure → mediator, mediator → outcome,
         exposure → outcome (per Pearl 2001). In A/B harness: exposure is randomly
         assigned per trial, so this holds between exposure and the other two.
      2. Binary outcome. Categorical mediator.
      3. Positive support — every (exposure, mediator) cell has ≥ min_cell trials.

    Returns dict with te, nde, nie, proportion_mediated, plus support counts.
    Returns None if support is inadequate.
    """
    # Partition rows
    by_exposure = defaultdict(list)
    for r in rows:
        e = r.get(exposure_col)
        if e not in (exposure_treatment, exposure_control):
            continue
        by_exposure[e].append(r)

    if not by_exposure.get(exposure_treatment) or not by_exposure.get(exposure_control):
        return None

    # Compute P(M=m | X=x) for each exposure level
    def mediator_dist(rs: list[dict]) -> dict:
        counts: dict = defaultdict(int)
        for r in rs:
            counts[r.get(mediator_col)] += 1
        total = sum(counts.values())
        if total == 0:
            return {}
        return {m: c / total for m, c in counts.items()}

    pm_given_treat = mediator_dist(by_exposure[exposure_treatment])
    pm_given_ctrl = mediator_dist(by_exposure[exposure_control])

    # Compute E[Y | X=x, M=m] for each combination
    def outcome_mean(rs: list[dict]) -> float | None:
        ys = [1 if r.get(outcome_col) else 0 for r in rs if outcome_col in r]
        return sum(ys) / len(ys) if ys else None

    ey_given = {}
    for exposure in (exposure_treatment, exposure_control):
        for m in set(pm_given_treat.keys()) | set(pm_given_ctrl.keys()):
            cell = [
                r
                for r in by_exposure[exposure]
                if r.get(mediator_col) == m
            ]
            mean = outcome_mean(cell)
            if mean is not None:
                ey_given[(exposure, m)] = mean

    # Compute total effect: E[Y | X=1] - E[Y | X=0]
    y_treat = outcome_mean(by_exposure[exposure_treatment])
    y_ctrl = outcome_mean(by_exposure[exposure_control])
    if y_treat is None or y_ctrl is None:
        return None
    te = y_treat - y_ctrl

    # Natural direct effect:
    #   NDE = sum_m { [E(Y | X=1, M=m) - E(Y | X=0, M=m)] * P(M=m | X=0) }
    # = expected outcome diff if exposure flipped but mediator stayed at its
    #   control-distribution value.
    mediator_values = set(pm_given_treat.keys()) | set(pm_given_ctrl.keys())
    nde = 0.0
    nde_support = True
    for m in mediator_values:
        p_ctrl = pm_given_ctrl.get(m, 0.0)
        if p_ctrl == 0.0:
            continue
        y_treat_m = ey_given.get((exposure_treatment, m))
        y_ctrl_m = ey_given.get((exposure_control, m))
        if y_treat_m is None or y_ctrl_m is None:
            nde_support = False
            break
        nde += (y_treat_m - y_ctrl_m) * p_ctrl

    # Natural indirect effect = TE - NDE
    nie = te - nde if nde_support else None

    return {
        "te": te,
        "nde": nde if nde_support else None,
        "nie": nie,
        "proportion_mediated": (nie / te) if (nde_support and nie is not None and te != 0) else None,
        "n_treatment": len(by_exposure[exposure_treatment]),
        "n_control": len(by_exposure[exposure_control]),
        "n_mediator_levels": len(mediator_values),
        "support_ok": nde_support,
    }


def bootstrap_effects(
    rows: list[dict],
    exposure_col: str,
    exposure_treatment: str,
    exposure_control: str,
    mediator_col: str,
    outcome_col: str,
    n_bootstrap: int = 10000,
    seed: int = 42,
) -> dict:
    """Bootstrap CI for TE, NDE, NIE."""
    rng = random.Random(seed)

    # Point estimate on the full dataset
    point = compute_effects(
        rows, exposure_col, exposure_treatment, exposure_control, mediator_col, outcome_col
    )
    if point is None:
        return {"error": "insufficient support on full dataset"}

    # Resample with replacement; collect estimates
    te_samples = []
    nde_samples = []
    nie_samples = []
    n_failures = 0

    for _ in range(n_bootstrap):
        resample = [rows[rng.randrange(len(rows))] for _ in rows]
        est = compute_effects(
            resample,
            exposure_col,
            exposure_treatment,
            exposure_control,
            mediator_col,
            outcome_col,
        )
        if est is None or not est.get("support_ok"):
            n_failures += 1
            continue
        te_samples.append(est["te"])
        nde_samples.append(est["nde"])
        nie_samples.append(est["nie"])

    def percentile_ci(samples: list[float], lo: float = 2.5, hi: float = 97.5):
        if not samples:
            return None, None
        s = sorted(samples)
        n = len(s)
        lo_idx = max(0, int(n * lo / 100.0))
        hi_idx = min(n - 1, int(n * hi / 100.0))
        return s[lo_idx], s[hi_idx]

    return {
        "point": point,
        "n_bootstrap": n_bootstrap,
        "n_bootstrap_failures": n_failures,
        "te_ci": percentile_ci(te_samples),
        "nde_ci": percentile_ci(nde_samples),
        "nie_ci": percentile_ci(nie_samples),
        "te_mean": statistics.mean(te_samples) if te_samples else None,
        "nde_mean": statistics.mean(nde_samples) if nde_samples else None,
        "nie_mean": statistics.mean(nie_samples) if nie_samples else None,
    }


# ---------------------------------------------------------------------------
# Self-test with synthetic data (NDE/NIE known)
# ---------------------------------------------------------------------------


def synthetic_data(n: int = 2000, seed: int = 7) -> tuple[list[dict], dict]:
    """Generate a dataset where NDE/NIE are analytically known.

    Model:
      X ∈ {A, B} uniform
      M ∈ {m0, m1} with P(M=m1 | X=A) = 0.80, P(M=m1 | X=B) = 0.20
      Y | (X, M=m0) = Bernoulli(0.30 if X=A else 0.20)
      Y | (X, M=m1) = Bernoulli(0.80 if X=A else 0.70)
    Analytical truth:
      NDE = Σ_m [E(Y|X=A,M=m) - E(Y|X=B,M=m)] * P(M=m|X=B)
          = (0.30-0.20)*0.80 + (0.80-0.70)*0.20
          = 0.08 + 0.02 = 0.10
      TE  = E(Y|X=A) - E(Y|X=B)
          = (0.20*0.30 + 0.80*0.80) - (0.80*0.20 + 0.20*0.70)
          = 0.70 - 0.30 = 0.40
      NIE = TE - NDE = 0.30
    """
    rng = random.Random(seed)
    rows = []
    for i in range(n):
        x = "A" if rng.random() < 0.5 else "B"
        p_m1 = 0.80 if x == "A" else 0.20
        m = "m1" if rng.random() < p_m1 else "m0"
        if x == "A":
            p_y = 0.80 if m == "m1" else 0.30
        else:
            p_y = 0.70 if m == "m1" else 0.20
        y = rng.random() < p_y
        rows.append({"cell": x, "category": m, "is_correct": y})
    truth = {"te": 0.40, "nde": 0.10, "nie": 0.30, "proportion_mediated": 0.75}
    return rows, truth


def run_self_test() -> int:
    print("=== mediation-analysis self-test ===")
    rows, truth = synthetic_data(n=2000, seed=7)
    result = bootstrap_effects(
        rows,
        exposure_col="cell",
        exposure_treatment="A",
        exposure_control="B",
        mediator_col="category",
        outcome_col="is_correct",
        n_bootstrap=1000,
        seed=42,
    )
    if "error" in result:
        print(f"FAIL: {result['error']}")
        return 1

    point = result["point"]
    print(f"\n  Analytical truth: TE={truth['te']:.3f} NDE={truth['nde']:.3f} NIE={truth['nie']:.3f}")
    print(
        f"  Estimated (n={len(rows)}):  "
        f"TE={point['te']:.3f} NDE={point['nde']:.3f} NIE={point['nie']:.3f}"
    )
    lo, hi = result["te_ci"]
    print(f"  TE  95% CI: [{lo:.3f}, {hi:.3f}]")
    lo, hi = result["nde_ci"]
    print(f"  NDE 95% CI: [{lo:.3f}, {hi:.3f}]")
    lo, hi = result["nie_ci"]
    print(f"  NIE 95% CI: [{lo:.3f}, {hi:.3f}]")

    # Validation: each point estimate within ± 0.03 of the truth.
    failures = []
    for key in ("te", "nde", "nie"):
        if abs(point[key] - truth[key]) > 0.03:
            failures.append(
                f"{key.upper()}: estimated {point[key]:.3f}, truth {truth[key]:.3f}, "
                f"delta {abs(point[key] - truth[key]):.3f} > 0.03"
            )

    # Validation: each truth value inside its bootstrap 95% CI.
    for key, ci_key in (("te", "te_ci"), ("nde", "nde_ci"), ("nie", "nie_ci")):
        lo, hi = result[ci_key]
        if not (lo <= truth[key] <= hi):
            failures.append(
                f"{key.upper()}: truth {truth[key]:.3f} not in CI [{lo:.3f}, {hi:.3f}]"
            )

    if failures:
        print("\nSELF-TEST FAILED:")
        for f in failures:
            print(f"  - {f}")
        return 1

    print("\nSELF-TEST PASSED — point estimates within ±0.03 of truth + truth inside CI.")
    return 0


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--self-test", action="store_true", help="Run self-test on synthetic data")
    ap.add_argument("--jsonl", type=Path, help="Input JSONL path")
    ap.add_argument("--exposure", default="cell")
    ap.add_argument("--exposure-treatment", default="A")
    ap.add_argument("--exposure-control", default="B")
    ap.add_argument("--mediator", default="category")
    ap.add_argument("--outcome", default="is_correct")
    ap.add_argument("--n-bootstrap", type=int, default=10000)
    ap.add_argument("--seed", type=int, default=42)
    ap.add_argument("--out", type=Path, help="Write result JSON to this path")
    args = ap.parse_args()

    if args.self_test:
        return run_self_test()

    if not args.jsonl or not args.jsonl.exists():
        ap.error("--jsonl required (or use --self-test)")

    rows = []
    with args.jsonl.open() as f:
        for line in f:
            if line.strip():
                rows.append(json.loads(line))

    print(f"Loaded {len(rows)} rows from {args.jsonl}")
    result = bootstrap_effects(
        rows,
        exposure_col=args.exposure,
        exposure_treatment=args.exposure_treatment,
        exposure_control=args.exposure_control,
        mediator_col=args.mediator,
        outcome_col=args.outcome,
        n_bootstrap=args.n_bootstrap,
        seed=args.seed,
    )

    if "error" in result:
        print(f"ERROR: {result['error']}", file=sys.stderr)
        return 1

    point = result["point"]
    print(f"\nTotal effect (TE):  {point['te']:+.4f}  95% CI {result['te_ci']}")
    print(f"Natural direct effect (NDE):  {point['nde']:+.4f}  95% CI {result['nde_ci']}")
    print(f"Natural indirect effect (NIE): {point['nie']:+.4f}  95% CI {result['nie_ci']}")
    if point["proportion_mediated"] is not None:
        print(f"Proportion mediated: {point['proportion_mediated']:+.3f}")
    print(f"Support: n_treatment={point['n_treatment']} n_control={point['n_control']} "
          f"mediator_levels={point['n_mediator_levels']}")

    if args.out:
        args.out.write_text(json.dumps(result, indent=2, default=str))
        print(f"\nWrote {args.out}")

    return 0


if __name__ == "__main__":
    sys.exit(main())
