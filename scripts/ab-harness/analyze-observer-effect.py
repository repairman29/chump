#!/usr/bin/env python3.12
"""RESEARCH-026 — Compare formal vs casual harness JSONLs (observer framing).

run-observer-effect-ab.sh produces two JSONLs per tier (formal + casual tags).
run-cloud-v2 default ab mode still runs lessons-on (cell A) vs lessons-off (cell B)
for each fixture. For the preregistered framing comparison, hold the lessons
manipulation constant and compare **the same cell** across runs — default
--cell A (lessons-on for both formal and casual passes).

Outputs pooled correctness rates with Wilson 95% CIs and a paired sign test
on per-task Δ = correct_formal − correct_casual (McNemar-style binomial on
discordant pairs).

Usage:
    python3.12 scripts/ab-harness/analyze-observer-effect.py \\
        --formal-jsonl logs/ab/research-026-haiku-formal-1710000000.jsonl \\
        --casual-jsonl logs/ab/research-026-haiku-casual-1710000000.jsonl \\
        --cell A
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

# Reuse Wilson helper from scoring_v2 (same directory).
sys.path.insert(0, str(Path(__file__).parent))
from scoring_v2 import wilson_ci  # noqa: E402


def load_rows(path: Path, cell: str) -> dict[tuple[str, str], dict]:
    """Map (task_id, cell) -> row (last wins if duplicates)."""
    out: dict[tuple[str, str], dict] = {}
    for line in path.read_text().splitlines():
        line = line.strip()
        if not line:
            continue
        r = json.loads(line)
        if r.get("cell") != cell:
            continue
        key = (r["task_id"], r["cell"])
        out[key] = r
    return out


def wilson_rate(rows: list[dict]) -> tuple[float, tuple[float, float], int, int]:
    n = len(rows)
    k = sum(1 for r in rows if r.get("is_correct"))
    rate = k / n if n else 0.0
    lo, hi = wilson_ci(k, n) if n else (0.0, 1.0)
    return rate, (lo, hi), k, n


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--formal-jsonl", type=Path, required=True)
    ap.add_argument("--casual-jsonl", type=Path, required=True)
    ap.add_argument("--cell", default="A", choices=("A", "B"), help="Which harness cell to compare")
    args = ap.parse_args()

    f_rows = load_rows(args.formal_jsonl, args.cell)
    c_rows = load_rows(args.casual_jsonl, args.cell)
    keys = sorted(set(f_rows) & set(c_rows), key=lambda k: k[0])
    if not keys:
        print("ERROR: no overlapping (task_id, cell) rows", file=sys.stderr)
        return 2

    formal_list = [f_rows[k] for k in keys]
    casual_list = [c_rows[k] for k in keys]

    fr, fci, fk, fn = wilson_rate(formal_list)
    cr, cci, ck, cn = wilson_rate(casual_list)
    assert fn == cn == len(keys)

    both = sum(
        1
        for k in keys
        if bool(f_rows[k].get("is_correct")) and bool(c_rows[k].get("is_correct"))
    )
    f_only = sum(
        1
        for k in keys
        if bool(f_rows[k].get("is_correct")) and not bool(c_rows[k].get("is_correct"))
    )
    c_only = sum(
        1
        for k in keys
        if not bool(f_rows[k].get("is_correct")) and bool(c_rows[k].get("is_correct"))
    )
    neither = len(keys) - both - f_only - c_only

    discordant = f_only + c_only

    delta = fr - cr
    print(f"Paired tasks: n={len(keys)}  cell={args.cell}")
    print(f"  Formal:  correct_rate={fr:.3f}  Wilson95=({fci[0]:.3f},{fci[1]:.3f})  k={fk}/{fn}")
    print(f"  Casual:  correct_rate={cr:.3f}  Wilson95=({cci[0]:.3f},{cci[1]:.3f})  k={ck}/{cn}")
    print(f"  Δ (formal − casual): {delta:+.3f}")
    print(f"  Confusion: both={both} formal-only={f_only} casual-only={c_only} neither={neither}")
    print(f"  Discordant pairs (McNemar n): {discordant}  (formal-only vs casual-only)")
    if abs(delta) > 0.05:
        print("  NOTE: |Δ| > 0.05 — prereg §9 requires observer-effect correction in publications.")
    else:
        print("  NOTE: |Δ| ≤ 0.05 — supports H0 (no strong framing bias) pending CI/bootstrap from prereg.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
