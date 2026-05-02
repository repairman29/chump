#!/usr/bin/env python3
# check-gaps-integrity.py — INFRA-075 CI check.
#
# Validates the gap registry: parses as YAML, has no duplicate `id:` values,
# and no entry has an empty id. Supports two layouts:
#
#   Per-file (INFRA-188 canonical):
#     python check-gaps-integrity.py --per-file docs/gaps/
#
#   Monolithic (legacy, kept for backward compat):
#     python check-gaps-integrity.py docs/gaps.yaml
#
# Exits non-zero (with a diagnostic) on any failure.
#
# Why this lives in CI on top of the pre-commit guard: the pre-commit
# duplicate-ID check only sees the locally-staged file. Two concurrent
# branches that each add the same id pass independently and only collide
# after the merge queue rebases server-side, where pre-commit hooks do
# not run. This script re-checks the rebased state.

import argparse
import os
import sys
from collections import Counter

import yaml


def load_gaps_from_dir(dir_path: str) -> list[dict]:
    """Load all gaps from per-file docs/gaps/*.yaml directory layout."""
    gaps = []
    if not os.path.isdir(dir_path):
        return gaps
    for fname in sorted(os.listdir(dir_path)):
        if not fname.endswith(".yaml"):
            continue
        fpath = os.path.join(dir_path, fname)
        try:
            with open(fpath) as f:
                content = f.read()
            parsed = yaml.safe_load(content)
            if isinstance(parsed, list):
                gaps.extend(g for g in parsed if isinstance(g, dict))
            elif isinstance(parsed, dict):
                gaps.append(parsed)
        except yaml.YAMLError as e:
            print(f"FAIL: {fpath} does not parse as YAML:\n  {e}", file=sys.stderr)
            sys.exit(1)
    return gaps


def load_gaps_from_monolithic(path: str) -> list[dict]:
    """Load all gaps from monolithic docs/gaps.yaml."""
    try:
        with open(path) as f:
            data = yaml.safe_load(f)
    except yaml.YAMLError as e:
        print(f"FAIL: {path} does not parse as YAML:\n  {e}", file=sys.stderr)
        sys.exit(1)
    except OSError as e:
        print(f"FAIL: cannot read {path}: {e}", file=sys.stderr)
        sys.exit(1)
    gaps = data.get("gaps") if isinstance(data, dict) else None
    if not isinstance(gaps, list):
        print(f"FAIL: {path} has no top-level `gaps:` list", file=sys.stderr)
        sys.exit(1)
    return gaps


def check_integrity(gaps: list[dict], source_label: str) -> int:
    ids = [g.get("id") for g in gaps if isinstance(g, dict)]
    missing = [i for i, gid in enumerate(ids) if not gid]
    if missing:
        print(
            f"FAIL: {len(missing)} gap entry(ies) have no `id:` (positions: {missing[:5]}...)",
            file=sys.stderr,
        )
        return 1

    counts = Counter(ids)
    dups = sorted(gid for gid, n in counts.items() if n > 1)
    if dups:
        print(f"FAIL: {source_label} contains duplicate id(s):", file=sys.stderr)
        for gid in dups:
            print(f"  - {gid} (appears {counts[gid]} times)", file=sys.stderr)
        print(
            "\nThe pre-commit duplicate-ID guard catches in-branch duplicates but\n"
            "cannot see ids added on a sibling branch. Resolve by renaming the\n"
            "more recently filed entry to the next free ID; record the rename in\n"
            "the entry's description for audit trail.",
            file=sys.stderr,
        )
        return 1

    print(f"OK: {source_label} parses; {len(ids)} unique gap ids.")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description="Validate gap registry integrity")
    parser.add_argument(
        "--per-file",
        metavar="DIR",
        help="Per-file layout: validate all *.yaml files in DIR (INFRA-188 canonical)",
    )
    parser.add_argument(
        "path",
        nargs="?",
        default="docs/gaps.yaml",
        help="Monolithic gaps.yaml path (legacy; default: docs/gaps.yaml)",
    )
    args = parser.parse_args()

    if args.per_file:
        gaps = load_gaps_from_dir(args.per_file)
        return check_integrity(gaps, f"docs/gaps/ directory ({len(gaps)} files)")
    else:
        gaps = load_gaps_from_monolithic(args.path)
        return check_integrity(gaps, args.path)


if __name__ == "__main__":
    sys.exit(main())
