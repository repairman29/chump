#!/usr/bin/env python3.12
"""EVAL-075: re-score EVAL-071 JSONL with refusal_with_instruction axis.

Usage:
    eval-075-rescore.py <ab.jsonl> [<ab.jsonl> ...] --model MODEL
"""
import argparse
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from scoring_v2 import detect_refusal_with_instruction, detect_honest_notool


def rescore_file(path: str, model: str) -> dict:
    cells: dict[str, dict] = {}
    with open(path) as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            row = json.loads(line)
            cell = row.get("cell", "all")
            if cell not in cells:
                cells[cell] = {"n": 0, "rwi": 0, "incorrect": 0, "incorrect_rwi": 0}
            c = cells[cell]
            text = row.get("agent_text_preview", row.get("response", "")) or ""
            is_correct = row.get("is_correct", False)
            rwi = detect_refusal_with_instruction(text)
            c["n"] += 1
            c["rwi"] += int(rwi)
            if not is_correct:
                c["incorrect"] += 1
                c["incorrect_rwi"] += int(rwi)

    return {"model": model, "file": path, "cells": cells}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("files", nargs="+")
    parser.add_argument("--model", default="unknown")
    args = parser.parse_args()

    print(f"# EVAL-075 refusal_with_instruction re-score\n")
    print(f"## Model: {args.model}\n")
    print(f"| File | Cell | n | RWI | RWI% | Incorrect | Incorr RWI | Incorr RWI% |")
    print(f"|---|---|---|---|---|---|---|---|")

    for fpath in args.files:
        r = rescore_file(fpath, args.model)
        fname = Path(fpath).name
        for cell, c in sorted(r["cells"].items()):
            n = c["n"]
            rwi = c["rwi"]
            inc = c["incorrect"]
            inc_rwi = c["incorrect_rwi"]
            print(f"| {fname} | {cell} | {n} | {rwi} | {rwi/n:.1%} | "
                  f"{inc} | {inc_rwi} | {inc_rwi/inc:.1%} |")

    print(f"\n**Interpretation:** RWI = refusal_with_instruction (teach-the-user mode)")
    print(f"Incorr RWI% = RWI fraction among incorrect responses (vs blank refusal, wrong answer, etc.)")


if __name__ == "__main__":
    main()
