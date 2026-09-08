#!/usr/bin/env python3
"""drift-flag-triage.py — CREDIBLE-222

Separates real config incoherence from representation noise in almanac's
CONFIG-organ DRIFT findings (see scripts/dev/drift-flag-extract.sh, which
pulls the raw findings-json this script consumes).

almanac already folds exact unset-sentinel spellings before counting drift
(INFRA-3472: "" / "(unset)" / "none" / ... -> one entry). What it does NOT
fold — and what left chump's ROADMAP O2 flagship claim unverified at scale
(211 flags, up from 181, "still untriaged") — are two further noise classes
this script adds on top, read-only, without touching almanac's own count:

1. Extended no-value sentinels almanac's list misses by spelling:
   "<unset>", "_unset_", "MISSING", "<none specified>", "not set", "unknown",
   "/dev/null" -- and test/mock placeholder literals ("*-mock-*",
   "*-dummy-*", "not-needed") that vary in text but all mean "no real
   default configured".
2. $VAR-interpolated path defaults that differ only by which local shell
   variable happens to hold the repo/lock-dir root (e.g. 44 spellings of
   "$X/.chump-locks/ambient.jsonl" for 44 different local $X names). Each
   default's resolved SHAPE strips any leading $VAR/${VAR}/{var} or "."
   root token before comparing, so "$REPO_ROOT/target" and "./target" and
   bare "target" all compare equal.

A flag survives triage as REAL drift only if, after folding unset/dynamic
sightings out of consideration, more than one distinct shape remains AND no
single shape dominates (>=65% of the surviving raw variants) — a handful of
one-off outliers against a wall of one true path (or "reads with the same
default 44 different ways") is exactly the representation-noise pattern
this triage exists to catch, not a case of different code paths assuming
different real behavior. The 65% dominance bar is deliberately generous to
REAL: a flag with a near-even split (e.g. two literal values at 50/50) is
never called NOISE by this rule, only a landslide-majority-plus-stragglers
pattern is. (Calibrated against the gap's own worked examples: it is the
threshold at which CHUMP_AMBIENT_LOG's 19-of-28 dominant shape — "44
variants that are nearly all the same path" — reads as NOISE while
CHUMPBAR_SSH_TIMEOUT's even 15-vs-6 split still reads as REAL.)

Usage:
    python3 scripts/dev/drift-flag-triage.py --in <findings.json> [--json]

Exit code is always 0 — this is a measurement/report tool, not a gate.
"""

import argparse
import json
import re
import sys
from pathlib import Path

# Sentinel spellings for "no real default" that almanac's own normalize_default
# (crates/almanac-organs/src/config.rs) does not fold, because they are not
# exact matches for its fixed UNSET_SENTINELS list.
EXTRA_UNSET_SENTINELS = {
    "<unset>",
    "_unset_",
    "missing",
    "<none specified>",
    "not set",
    "unknown",
}

# Literal placeholder values that read as distinct text but are all
# "no real value configured" scaffolding (test mocks, disabled-provider
# markers), not a genuine behavioral fork.
MOCK_PLACEHOLDER_RE = re.compile(
    r"(mock|dummy|fake|not[- ]needed)", re.IGNORECASE
)

# Sink/discard paths that mean "no real value" for a log/output path flag.
SINK_PATHS = {"/dev/null", "nul", "os.devnull"}

# A single path segment that is just a variable reference: $FOO, ${FOO},
# {foo} — the "different local variable names, same path" case.
VAR_SEGMENT_RE = re.compile(r"^(\$\{?[A-Za-z_][A-Za-z0-9_]*\}?|\{[A-Za-z_][A-Za-z0-9_]*\})$")

DYNAMIC = "<dynamic>"
UNSET = "∅"  # empty-set marker for "no value"

# A shape group must cover at least this fraction of the surviving (non-
# unset, non-dynamic) raw variants to be considered "dominant" — the rest
# treated as noise-adjacent stragglers rather than proof of real drift.
DOMINANCE_THRESHOLD = 0.65


def is_unset_like(v: str) -> bool:
    v = v.strip()
    if v == "":
        return True
    if v.lower() in EXTRA_UNSET_SENTINELS:
        return True
    if v.lower() in SINK_PATHS:
        return True
    if MOCK_PLACEHOLDER_RE.search(v):
        return True
    return False


def path_shape(v: str) -> str:
    """Resolved shape of a path default: strip any leading $VAR/${VAR}/
    {var}/"." root token(s) so different local variable names (or a bare
    relative path vs an explicit "./" prefix) naming the same root compare
    equal. Safe no-op for non-path bare tokens (enum-like literals, numbers,
    URLs without a leading var segment) since there is nothing to strip."""
    parts = [p for p in v.split("/") if p != ""]
    if not parts:
        return v
    i = 0
    while i < len(parts) - 1 and (VAR_SEGMENT_RE.match(parts[i]) or parts[i] == "."):
        i += 1
    return "/".join(parts[i:])


def normalize(v: str) -> str:
    v = v.strip()
    if v == DYNAMIC:
        return DYNAMIC
    if is_unset_like(v):
        return UNSET
    return path_shape(v)


def triage_flag(defaults: list[str]) -> tuple[str, list[str]]:
    """Returns (verdict, sorted_distinct_shapes) where verdict is REAL or
    NOISE per the dominance rule described in the module docstring."""
    shapes = [normalize(d) for d in defaults]
    real_shapes = [s for s in shapes if s not in (UNSET, DYNAMIC)]
    distinct_groups = sorted(set(shapes))

    if not real_shapes:
        return "NOISE", distinct_groups

    counts: dict[str, int] = {}
    for s in real_shapes:
        counts[s] = counts.get(s, 0) + 1
    if len(counts) == 1:
        return "NOISE", distinct_groups

    dominant_share = max(counts.values()) / len(real_shapes)
    verdict = "NOISE" if dominant_share >= DOMINANCE_THRESHOLD else "REAL"
    return verdict, distinct_groups


def load_findings(path: Path) -> list[dict]:
    with open(path) as f:
        data = json.load(f)
    # drift-flag-extract.sh stores the raw comprehend --findings-json output,
    # which is a flat list of findings (kind in {"drift","bypass","wiring"}).
    if isinstance(data, dict) and "findings" in data:
        data = data["findings"]
    return [f for f in data if str(f.get("kind", "")).lower() == "drift"]


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--in", dest="in_file", required=True, help="raw findings-json from drift-flag-extract.sh")
    ap.add_argument("--json", action="store_true")
    args = ap.parse_args()

    drift_findings = load_findings(Path(args.in_file))

    rows = []
    for finding in drift_findings:
        ctx = finding.get("context", finding)
        flag = ctx.get("flag") or finding.get("flag") or finding.get("title", "?")
        defaults = ctx.get("defaults", [])
        reads = ctx.get("reads", 0)
        verdict, groups = triage_flag(defaults)
        rows.append(
            {
                "flag": flag,
                "reads": reads,
                "raw_defaults": defaults,
                "normalized_groups": groups,
                "verdict": verdict,
            }
        )

    real = [r for r in rows if r["verdict"] == "REAL"]
    noise = [r for r in rows if r["verdict"] == "NOISE"]

    summary = {
        "total_drift_flags": len(rows),
        "real_count": len(real),
        "noise_count": len(noise),
    }

    if args.json:
        print(json.dumps({"summary": summary, "rows": rows}, indent=2))
    else:
        print(f"total DRIFT flags: {summary['total_drift_flags']}")
        print(f"  REAL  (survive triage): {summary['real_count']}")
        print(f"  NOISE (representation artifact): {summary['noise_count']}")
        print()
        print("REAL, sorted by reads desc:")
        for r in sorted(real, key=lambda r: -r["reads"]):
            print(f"  {r['reads']:>5}  {r['flag']:<30} {r['normalized_groups']}")

    return 0


if __name__ == "__main__":
    sys.exit(main())
