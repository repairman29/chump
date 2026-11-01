#!/usr/bin/env python3.12
"""EVAL-071 analysis — hallucinated-tool inflation across non-Anthropic models.

Computes per-model:
  - Cell A (no lessons) halluc rate vs Cell B (lessons) halluc rate
  - Delta (B - A), 95% CI by normal approx
  - A/A noise floor from paired A/A run
  - Ratio of A/B delta to A/A noise (F2 used 10.7x)
  - is_correct delta as secondary signal

Usage: eval-071-analyze.py <ab.jsonl> <aa.jsonl> --model <name>
"""
import json
import sys
import argparse
import math
from collections import defaultdict


def load(path):
    rows = []
    with open(path) as f:
        for line in f:
            line = line.strip()
            if line:
                rows.append(json.loads(line))
    return rows


def rate(rows, key):
    n = len(rows)
    if n == 0:
        return 0.0, 0
    k = sum(1 for r in rows if r.get(key))
    return k / n, n


def ci95(p, n):
    if n == 0:
        return 0.0
    return 1.96 * math.sqrt(p * (1 - p) / n)


def split_cells(rows):
    cells = defaultdict(list)
    for r in rows:
        cells[r["cell"]].append(r)
    return cells


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("ab_jsonl")
    ap.add_argument("aa_jsonl")
    ap.add_argument("--model", required=True)
    args = ap.parse_args()

    ab = load(args.ab_jsonl)
    aa = load(args.aa_jsonl)

    ab_cells = split_cells(ab)
    aa_cells = split_cells(aa)

    # A/B analysis
    a_halluc, a_n = rate(ab_cells.get("A", []), "hallucinated_tools")
    b_halluc, b_n = rate(ab_cells.get("B", []), "hallucinated_tools")
    a_correct, _ = rate(ab_cells.get("A", []), "is_correct")
    b_correct, _ = rate(ab_cells.get("B", []), "is_correct")

    halluc_delta = b_halluc - a_halluc
    correct_delta = b_correct - a_correct

    # A/A noise floor — split into two halves for pseudo-A/A comparison
    aa_rows = aa_cells.get("A", []) + aa_cells.get("B", [])
    half = len(aa_rows) // 2
    aa1_halluc, _ = rate(aa_rows[:half], "hallucinated_tools")
    aa2_halluc, _ = rate(aa_rows[half:], "hallucinated_tools")
    aa_noise = abs(aa1_halluc - aa2_halluc)

    ratio = halluc_delta / aa_noise if aa_noise > 0 else float("inf")

    print(f"# EVAL-071 results: {args.model}")
    print()
    print(f"## Sample sizes")
    print(f"- A/B: A={a_n}, B={b_n}")
    print(f"- A/A total: {len(aa_rows)} (split halves: {half} / {len(aa_rows)-half})")
    print()
    print(f"## Hallucinated-tool rates")
    print(f"- Cell A (no lessons): {a_halluc*100:.2f}% (n={a_n}, ±{ci95(a_halluc, a_n)*100:.2f}pp)")
    print(f"- Cell B (lessons):    {b_halluc*100:.2f}% (n={b_n}, ±{ci95(b_halluc, b_n)*100:.2f}pp)")
    print(f"- **Delta B-A:         {halluc_delta*100:+.2f}pp**")
    print()
    print(f"## A/A noise floor")
    print(f"- Halves split halluc: {aa1_halluc*100:.2f}% vs {aa2_halluc*100:.2f}%")
    print(f"- Noise floor:         {aa_noise*100:.2f}pp")
    print(f"- **Ratio delta/noise: {ratio:.1f}x** (F2 Anthropic baseline: 10.7x)")
    print()
    print(f"## Correctness (secondary)")
    print(f"- Cell A correct: {a_correct*100:.2f}%")
    print(f"- Cell B correct: {b_correct*100:.2f}%")
    print(f"- **Delta B-A:    {correct_delta*100:+.2f}pp**")
    print()
    print(f"## Verdict")
    if halluc_delta > 0 and ratio > 3:
        print(f"- F2 EXTENDS to {args.model}: halluc inflation +{halluc_delta*100:.2f}pp at {ratio:.1f}x noise")
    elif halluc_delta <= 0 or ratio < 1:
        print(f"- F2 does NOT extend to {args.model}: null/negative result (delta={halluc_delta*100:+.2f}pp, ratio={ratio:.1f}x)")
    else:
        print(f"- F2 status AMBIGUOUS on {args.model}: delta={halluc_delta*100:+.2f}pp, ratio={ratio:.1f}x — need larger n")


if __name__ == "__main__":
    main()
