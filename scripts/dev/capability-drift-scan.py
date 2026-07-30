#!/usr/bin/env python3
"""capability-drift-scan.py — CREDIBLE-173

Diffs the real src/ + crates/*/src/ module tree against
docs/observability/CAPABILITY_BUCKETS.yaml and flags LOC clusters with no
bucket attribution above a threshold. This is the mechanized backstop for the
"a capability scan finds what it's told to look for" failure documented in
docs/CODEBASE_REALITY_MAP.md §0/§3 — instead of rediscovering blind spots by
a one-time manual sweep, drift is flagged automatically.

Usage:
    python3 scripts/dev/capability-drift-scan.py [--threshold-loc N] [--json]

Exit code is always 0 (this is a signal, not a gate — MISSION-045 "signals
are not work": a flagged blind spot is triaged by an operator/curator, never
auto-filed as a gap by this script).
"""

import argparse
import fnmatch
import json
import subprocess
import sys
from collections import defaultdict
from pathlib import Path

import yaml

REPO_ROOT = Path(__file__).resolve().parent.parent.parent
REGISTRY_PATH = REPO_ROOT / "docs/observability/CAPABILITY_BUCKETS.yaml"
DEFAULT_THRESHOLD = 200  # LOC — below this, an unattributed cluster is noise


def load_registry() -> list[dict]:
    with open(REGISTRY_PATH) as f:
        data = yaml.safe_load(f)
    return data.get("buckets", [])


def real_rust_files() -> list[str]:
    """Every .rs file tracked by git under src/ and crates/*/src/."""
    out = subprocess.run(
        ["git", "-C", str(REPO_ROOT), "ls-files", "src/**/*.rs", "crates/*/src/**/*.rs"],
        capture_output=True,
        text=True,
        check=False,
    )
    files = [line for line in out.stdout.splitlines() if line.strip()]
    if files:
        return files
    # git ls-files with ** globs needs --recurse or a shell glob fallback on
    # some git versions; fall back to a direct filesystem walk.
    files = []
    for base in ["src", "crates"]:
        base_path = REPO_ROOT / base
        if base_path.exists():
            files.extend(
                str(p.relative_to(REPO_ROOT)) for p in base_path.rglob("*.rs")
            )
    return files


def loc(path: Path) -> int:
    try:
        with open(path, "r", errors="ignore") as f:
            return sum(1 for _ in f)
    except OSError:
        return 0


def matches_any_bucket(rel_path: str, buckets: list[dict]) -> str | None:
    for bucket in buckets:
        for pattern in bucket["globs"]:
            if fnmatch.fnmatch(rel_path, pattern):
                return bucket["name"]
    return None


def cluster_key(rel_path: str) -> str:
    """Group unattributed files into a coherent unit. crates/*/src/** groups
    by crate name (a new crate should show up as one cluster, not N files).
    src/** is a KNOWN FLAT layout (main.rs has 249 mod decls, ~no subdirs per
    CODEBASE_REALITY_MAP.md) — grouping flat src/*.rs files by "src" produces
    one useless mega-cluster, so those are keyed per-file instead. A src/
    subdirectory (e.g. src/commands/*) still groups by that subdirectory."""
    parts = Path(rel_path).parts
    if parts[0] == "crates" and len(parts) > 1:
        return f"crates/{parts[1]}"
    if parts[0] == "src" and len(parts) > 2:
        return f"src/{parts[1]}"  # a real subdirectory — group it
    return rel_path  # flat src/*.rs — report per-file


def emit_ambient_event(clusters: dict[str, int], threshold: int) -> None:
    """Emits kind=capability_drift_detected — a signal, never an auto-filed
    gap, per MISSION-045."""
    ambient_path = REPO_ROOT / ".chump-locks/ambient.jsonl"
    if not ambient_path.parent.exists():
        return
    import time

    event = {
        "ts": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "kind": "capability_drift_detected",
        "threshold_loc": threshold,
        "flagged_clusters": [
            {"cluster": k, "loc": v} for k, v in sorted(clusters.items(), key=lambda kv: -kv[1])
        ],
        "flagged_count": len(clusters),
    }
    with open(ambient_path, "a") as f:
        f.write(json.dumps(event) + "\n")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--threshold-loc", type=int, default=DEFAULT_THRESHOLD)
    parser.add_argument("--json", action="store_true")
    parser.add_argument(
        "--no-emit", action="store_true", help="skip writing to ambient.jsonl (for tests/dry-run)"
    )
    args = parser.parse_args()

    buckets = load_registry()
    files = real_rust_files()

    unattributed_loc: dict[str, int] = defaultdict(int)
    for rel_path in files:
        full_path = REPO_ROOT / rel_path
        if not full_path.exists():
            continue
        bucket = matches_any_bucket(rel_path, buckets)
        if bucket is None:
            unattributed_loc[cluster_key(rel_path)] += loc(full_path)

    flagged = {k: v for k, v in unattributed_loc.items() if v >= args.threshold_loc}

    if args.json:
        print(json.dumps({"threshold_loc": args.threshold_loc, "flagged": flagged}, indent=2))
    else:
        if not flagged:
            print(f"[capability-drift-scan] clean — no unattributed cluster >= {args.threshold_loc} LOC")
        else:
            print(f"[capability-drift-scan] {len(flagged)} unattributed cluster(s) >= {args.threshold_loc} LOC:")
            ranked = sorted(flagged.items(), key=lambda kv: -kv[1])
            TOP_N = 25
            for k, v in ranked[:TOP_N]:
                print(f"  {v:6d} LOC  {k}")
            if len(ranked) > TOP_N:
                print(f"  ... and {len(ranked) - TOP_N} more (use --json for the full list)")
            print("\nThese don't match any bucket in docs/observability/CAPABILITY_BUCKETS.yaml.")
            print("Triage: either add a bucket entry (it's a real capability area), or it's genuinely")
            print("dead/vendored code worth a separate look. Not auto-filed as a gap (MISSION-045).")

    if flagged and not args.no_emit:
        emit_ambient_event(flagged, args.threshold_loc)

    return 0  # signal, not a gate — see MISSION-045 in the module docstring


if __name__ == "__main__":
    sys.exit(main())
