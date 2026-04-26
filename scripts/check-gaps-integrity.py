#!/usr/bin/env python3
# check-gaps-integrity.py — INFRA-075 CI check.
#
# Validates docs/gaps.yaml: parses as YAML, has a top-level `gaps:` list,
# and contains no duplicate `id:` values. Exits non-zero (with a diagnostic)
# on any failure.
#
# Why this lives in CI on top of the pre-commit guard: the pre-commit
# duplicate-ID check only sees the locally-staged file. Two concurrent
# branches that each add the same id pass independently and only collide
# after the merge queue rebases server-side, where pre-commit hooks do
# not run. This script re-checks the rebased state.

import sys
from collections import Counter

import yaml


def main(path: str) -> int:
    try:
        with open(path) as f:
            data = yaml.safe_load(f)
    except yaml.YAMLError as e:
        print(f"FAIL: {path} does not parse as YAML:\n  {e}", file=sys.stderr)
        return 1
    except OSError as e:
        print(f"FAIL: cannot read {path}: {e}", file=sys.stderr)
        return 1

    gaps = data.get("gaps") if isinstance(data, dict) else None
    if not isinstance(gaps, list):
        print(f"FAIL: {path} has no top-level `gaps:` list", file=sys.stderr)
        return 1

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
        print("FAIL: docs/gaps.yaml contains duplicate id(s):", file=sys.stderr)
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

    print(f"OK: {path} parses; {len(ids)} unique gap ids.")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1] if len(sys.argv) > 1 else "docs/gaps.yaml"))
