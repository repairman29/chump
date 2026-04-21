#!/usr/bin/env python3
"""EVAL-073 — join both-strict rescore outputs and compute cross-judge agreement per fixture."""
import json
import sys
from pathlib import Path
from collections import defaultdict

BASE = Path(__file__).resolve().parents[2] / "logs" / "ab"
SONNET = BASE / "eval-073-sonnet-strict.jsonl"
LLAMA = BASE / "eval-073-llama-strict.jsonl"


def load(p):
    rows = {}
    for line in p.read_text().splitlines():
        d = json.loads(line)
        key = (d["task_id"], d["cell"])
        rows[key] = d
    return rows


def fixture_of(task_id):
    if task_id.startswith(("structured", "trivial")) and "dynamic" not in task_id:
        return "perception"
    if task_id.startswith(("dynamic",)):
        return "neuromod"
    return "reflection"


def bin_score(x):
    if x is None:
        return None
    try:
        return 1 if float(x) >= 0.5 else 0
    except (TypeError, ValueError):
        return None


def main():
    sonnet = load(SONNET)
    llama = load(LLAMA)
    common = sorted(set(sonnet) & set(llama))
    by_fix = defaultdict(lambda: {"n": 0, "agree": 0, "s1l1": 0, "s0l0": 0, "s1l0": 0, "s0l1": 0})

    # Need the task_id prefix. But neuromod rows use "dynamic-" prefix which I
    # treat via fixture_of. Better: use the row's source fixture via category +
    # input file hints — but rescore merges them. Use cell as proxy — cell is
    # the agent cell (model/variant), not fixture. Instead classify by task_id.
    task_to_fixture = {}
    # reflection fixture tasks have id that doesn't start structured/trivial/dynamic
    # Let me read source fixtures directly.
    src_dir = BASE
    for src, name in [
        (src_dir.glob("eval-042-crossjudge-reflection-*.jsonl"), "reflection"),
        (src_dir.glob("eval-042-crossjudge-perception-*.jsonl"), "perception"),
        (src_dir.glob("eval-042-crossjudge-neuromod-*.jsonl"), "neuromod"),
    ]:
        for f in src:
            for line in f.read_text().splitlines():
                d = json.loads(line)
                task_to_fixture[d["task_id"]] = name

    per_fix_rows = defaultdict(list)
    for key in common:
        tid, cell = key
        fix = task_to_fixture.get(tid, "unknown")
        s_new = bin_score(sonnet[key].get("judge_score"))
        l_new = bin_score(llama[key].get("judge_score"))
        s_orig = bin_score(sonnet[key].get("judge_score_claude_sonnet_4_5"))
        if s_new is None or l_new is None:
            continue
        rec = by_fix[fix]
        rec["n"] += 1
        if s_new == l_new:
            rec["agree"] += 1
        key_quad = f"s{s_new}l{l_new}"
        rec[key_quad] += 1
        per_fix_rows[fix].append((tid, cell, s_orig, s_new, l_new))

    print("=" * 64)
    print("EVAL-073 Both-Strict Cross-Judge Agreement")
    print("  New judge A: anthropic:claude-sonnet-4-5 (strict prompt)")
    print("  New judge B: together:meta-llama/Llama-3.3-70B-Instruct-Turbo (strict)")
    print("=" * 64)
    header = f"{'Fixture':<12} {'N':>4} {'Agree':>6} {'Agree%':>8}  {'both1':>6} {'both0':>6} {'S1L0':>6} {'S0L1':>6}"
    print(header)
    print("-" * len(header))
    total_n = 0
    total_agree = 0
    for fix in ("reflection", "perception", "neuromod"):
        r = by_fix.get(fix, {"n": 0, "agree": 0, "s1l1": 0, "s0l0": 0, "s1l0": 0, "s0l1": 0})
        if r["n"] == 0:
            continue
        pct = 100.0 * r["agree"] / r["n"]
        print(f"{fix:<12} {r['n']:>4} {r['agree']:>6} {pct:>7.1f}%  {r['s1l1']:>6} {r['s0l0']:>6} {r['s1l0']:>6} {r['s0l1']:>6}")
        total_n += r["n"]
        total_agree += r["agree"]
    print("-" * len(header))
    if total_n:
        pct = 100.0 * total_agree / total_n
        print(f"{'TOTAL':<12} {total_n:>4} {total_agree:>6} {pct:>7.1f}%")
    print("=" * 64)


if __name__ == "__main__":
    main()
