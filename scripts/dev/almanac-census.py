#!/usr/bin/env python3
"""almanac-census.py — EFFECTIVE-391

`almanac census <concept>` — every implementation of a concept across
registered repos, literal-copy detection by structural identity, and an
extractability signal from real index data. Answers the question the retry
probe (2026-08-07, EFFECTIVE-391 gap description) surfaced by hand:
`almanac_search_fleet 'retry exponential backoff'` returned implementations
scattered across a dozen repos, several of them provably the SAME code
(same symbol, same line) rather than convergent design, and one of them —
`smugglers/shared-utils/retry-patterns/` — proves an extraction ALREADY
HAPPENED and never propagated. That is the fleet's latent-value shape in
one query: not missing capability, unpropagated capability.

This is chump-side, not almanac-side (same posture as
`scripts/dev/almanac-zero-hits.py`, EFFECTIVE-380): the almanac CLI/index
lives in the separate repairman29/almanac repo, not guaranteed to be
checked out in every chump worktree. This script shells out to the `almanac`
CLI's `search-fleet` / `impact` / `neighbors` / `coverage` subcommands
(`--json`) and degrades honestly when the binary or index is absent, rather
than fabricating numbers.

Structural-identity rule (AC2) — two tiers, both flagged as a copy, kept
distinct because they are different strength of evidence:
  - "verbatim": same symbol name + same relative path + same start line
    (e.g. RetryService at src/services/retryService.js:6 in three repos —
    a wholesale directory copy).
  - "moved": same symbol name + same start line, DIFFERENT relative path
    (e.g. bulwark:src/retry-patterns.js:10 vs
    smugglers:shared-utils/retry-patterns/index.js:10 — the class moved
    when it was extracted, but the symbol and line survived the move).
Independently-written sites (different symbol name entirely) are never
merged into another symbol's row — see the vocabulary caveat below.

Extractability (AC3) needs three real inputs per cluster: importer counts
(`almanac impact`), coupling (`almanac neighbors`), and test presence. If
any of the three could not be obtained for a cluster, the script reports
`extractability: null` and names exactly which input(s) were unavailable —
it never scores on two-of-three and calls it a signal.

Vocabulary honesty (AC5): `search-fleet` is a KEYWORD index. This script
groups strictly by exact (case-insensitive) symbol name — it cannot and
does not attempt to unify differently-named implementations of the same
idea (`retry_with_backoff` vs `withRetry` vs `BackoffTimer` never merge).
Every report states this plainly and carries the last known fleet embedding
coverage number so a reader knows how much of the fleet this blind spot
still covers.

Usage:
    python3 scripts/dev/almanac-census.py "<concept>" [--json]
    python3 scripts/dev/almanac-census.py "<concept>" --fixture PATH [--json]
    python3 scripts/dev/almanac-census.py "<concept>" --almanac-bin PATH

Exit code is always 0 — this is a report for a human to act on (extract,
adopt, or ignore), not an enforcement gate.
"""

import argparse
import json
import shutil
import subprocess
import sys
from dataclasses import dataclass, field
from pathlib import Path

DEFAULT_LIMIT = 50
# Last measured fleet embedding coverage (docs/process, EFFECTIVE-380 probe,
# 2026-08-07) — the honest fallback when `almanac coverage` can't be reached
# live. Always prefer the live number when available.
FALLBACK_EMBEDDING_COVERAGE_PCT = 15
FALLBACK_EMBEDDING_COVERAGE_ASOF = "2026-08-07"

# Path substrings that mark a site as a deliberate, named extraction rather
# than an incidental implementation — the smugglers/shared-utils/ proof
# case. Kept narrow and documented rather than guessed per-repo.
SHARED_EXTRACTION_PATTERNS = (
    "shared-utils/",
    "shared_utils/",
    "/shared/",
    "packages/shared",
    "lib/shared",
    "common/",
)


def almanac_bin(explicit: str = None) -> str:
    if explicit:
        return explicit
    home = str(Path.home())
    for candidate in (
        f"{home}/Projects/almanac/target/release/almanac",
        f"{home}/Projects/almanac/target/debug/almanac",
    ):
        if Path(candidate).is_file():
            return candidate
    found = shutil.which("almanac")
    return found or ""


def run_almanac(bin_path: str, args: list) -> dict:
    """Run one almanac subcommand with --json. Returns
    {"ok": bool, "data": ..., "error": str}. Never raises — a missing
    binary, a timeout, or unparsable output are all reported, not crashed
    on, because the whole point of this tool is to be honest about what it
    could not verify."""
    if not bin_path:
        return {"ok": False, "data": None, "error": "almanac binary not found"}
    try:
        proc = subprocess.run(
            [bin_path, *args, "--json"],
            capture_output=True,
            text=True,
            timeout=30,
            check=False,
        )
    except (subprocess.TimeoutExpired, OSError) as exc:
        return {"ok": False, "data": None, "error": f"{type(exc).__name__}: {exc}"}
    if proc.returncode != 0:
        return {
            "ok": False,
            "data": None,
            "error": f"exit {proc.returncode}: {proc.stderr.strip()[:300]}",
        }
    try:
        return {"ok": True, "data": json.loads(proc.stdout), "error": None}
    except json.JSONDecodeError as exc:
        return {"ok": False, "data": None, "error": f"unparsable JSON: {exc}"}


def _first(d: dict, *keys):
    for k in keys:
        if k in d and d[k] is not None:
            return d[k]
    return None


@dataclass
class Site:
    repo: str
    path: str
    line: int
    symbol: str
    importer_count: int = None
    coupling: int = None
    has_tests: bool = None

    @property
    def key(self):
        return f"{self.repo}:{self.path}:{self.line}"


def normalize_hit(raw: dict) -> Site:
    """`search-fleet --json` hit shape isn't pinned down by a schema this
    repo owns (the almanac binary lives in a sibling repo) — normalize
    across the field-name spellings a keyword-search result is likely to
    use rather than assume one exact shape."""
    return Site(
        repo=str(_first(raw, "repo", "repository", "repo_name") or ""),
        path=str(_first(raw, "path", "file", "file_path", "relative_path") or ""),
        line=int(_first(raw, "line", "line_number", "start_line") or 0),
        symbol=str(_first(raw, "symbol", "symbol_name", "name") or ""),
        importer_count=_first(raw, "importer_count", "importers"),
        coupling=_first(raw, "coupling", "neighbor_count"),
        has_tests=_first(raw, "has_tests", "test_presence"),
    )


def load_sites(concept: str, limit: int, fixture: Path, bin_path: str) -> dict:
    """Returns {"sites": [Site], "mode": str, "note": str}."""
    if fixture:
        raw = json.loads(fixture.read_text())
        return {
            "sites": [normalize_hit(h) for h in raw],
            "mode": "fixture",
            "note": f"loaded from fixture {fixture}, no live almanac call made",
        }
    result = run_almanac(bin_path, ["search-fleet", concept, "--limit", str(limit)])
    if not result["ok"]:
        return {
            "sites": [],
            "mode": "unavailable",
            "note": (
                "almanac search-fleet unavailable "
                f"({result['error']}) — this census has NO DATA, it is not "
                "a clean zero-hit; do not treat an empty report as proof "
                "the concept has zero implementations"
            ),
        }
    hits = result["data"] if isinstance(result["data"], list) else result["data"].get("hits", [])
    return {
        "sites": [normalize_hit(h) for h in hits],
        "mode": "keyword",
        "note": "live almanac search-fleet, keyword mode",
    }


def enrich_site(site: Site, bin_path: str, cache: dict) -> list:
    """Best-effort fill of importer_count / coupling / has_tests via
    `almanac impact` + `almanac neighbors` when the search hit didn't carry
    them already (fixtures may supply them directly to avoid live calls in
    tests). Returns a list of input names that remain unavailable."""
    missing = []
    if site.importer_count is None:
        cache_key = ("impact", site.repo, site.path)
        if cache_key not in cache:
            cache[cache_key] = run_almanac(bin_path, ["impact", site.repo, site.path])
        res = cache[cache_key]
        if res["ok"] and isinstance(res["data"], dict):
            importers = _first(res["data"], "importers", "importer_count")
            if isinstance(importers, list):
                site.importer_count = len(importers)
            elif isinstance(importers, int):
                site.importer_count = importers
        if site.importer_count is None:
            missing.append("importer_count")

    if site.coupling is None or site.has_tests is None:
        cache_key = ("neighbors", site.repo, site.path)
        if cache_key not in cache:
            cache[cache_key] = run_almanac(bin_path, ["neighbors", site.repo, site.path])
        res = cache[cache_key]
        if res["ok"] and isinstance(res["data"], dict):
            imports = _first(res["data"], "imports", "imported_by") or []
            imported_by = _first(res["data"], "imported_by", "importers") or []
            if site.coupling is None:
                site.coupling = len(imports) + len(imported_by)
            if site.has_tests is None:
                names = [str(x) for x in list(imports) + list(imported_by)]
                site.has_tests = any(
                    "test" in n.lower() or "spec" in n.lower() for n in names
                )
        if site.coupling is None:
            missing.append("coupling")
        if site.has_tests is None:
            missing.append("test_presence")
    return missing


@dataclass
class Cluster:
    symbol: str
    sites: list = field(default_factory=list)
    missing_inputs: set = field(default_factory=set)


def cluster_by_symbol(sites: list) -> list:
    by_symbol = {}
    for s in sites:
        if not s.symbol:
            continue
        key = s.symbol.strip().lower()
        by_symbol.setdefault(key, Cluster(symbol=s.symbol, sites=[])).sites.append(s)
    clusters = list(by_symbol.values())
    clusters.sort(key=lambda c: len(c.sites), reverse=True)
    return clusters


def detect_copies(cluster: Cluster) -> list:
    """Union-find over pairwise structural identity. Returns a list of
    copy-groups, each a list of site dicts plus a 'tier' (verbatim | moved).
    A cluster with only one site can never be a copy of anything."""
    sites = cluster.sites
    n = len(sites)
    parent = list(range(n))

    def find(x):
        while parent[x] != x:
            parent[x] = parent[parent[x]]
            x = parent[x]
        return x

    def union(a, b):
        ra, rb = find(a), find(b)
        if ra != rb:
            parent[ra] = rb

    pair_tier = {}
    for i in range(n):
        for j in range(i + 1, n):
            a, b = sites[i], sites[j]
            if a.line == b.line and a.line != 0:
                tier = "verbatim" if a.path == b.path else "moved"
                union(i, j)
                pair_tier[(find(i), i, j)] = tier

    groups = {}
    for i in range(n):
        groups.setdefault(find(i), []).append(i)

    copy_groups = []
    for root, members in groups.items():
        if len(members) < 2:
            continue
        # A group is "verbatim" only if every pairing that formed it shared
        # a path; a single moved pairing downgrades the whole group's label
        # to "moved" so the report never overstates the evidence.
        tiers = set()
        for i in range(len(members)):
            for j in range(i + 1, len(members)):
                a, b = sites[members[i]], sites[members[j]]
                if a.line == b.line:
                    tiers.add("verbatim" if a.path == b.path else "moved")
        tier = "verbatim" if tiers == {"verbatim"} else "moved"
        copy_groups.append(
            {
                "tier": tier,
                "sites": [sites[i].key for i in members],
            }
        )
    return copy_groups


def find_existing_extraction(cluster: Cluster):
    for s in cluster.sites:
        low = s.path.lower()
        if any(pat in low for pat in SHARED_EXTRACTION_PATTERNS):
            non_adopters = [x.repo for x in cluster.sites if x.repo != s.repo]
            if non_adopters:
                return {
                    "site": s.key,
                    "message": (
                        f"already extracted at {s.key} — "
                        f"{len(non_adopters)} repo(s) have not adopted it: "
                        f"{', '.join(sorted(set(non_adopters)))}"
                    ),
                }
    return None


def score_extractability(cluster: Cluster):
    missing = set()
    importer_counts = []
    couplings = []
    test_flags = []
    for s in cluster.sites:
        if s.importer_count is None:
            missing.add("importer_count")
        else:
            importer_counts.append(s.importer_count)
        if s.coupling is None:
            missing.add("coupling")
        else:
            couplings.append(s.coupling)
        if s.has_tests is None:
            missing.add("test_presence")
        else:
            test_flags.append(s.has_tests)

    if missing:
        return {
            "score": None,
            "unavailable_inputs": sorted(missing),
            "note": (
                "not scored — real inputs unavailable for at least one "
                f"site: {', '.join(sorted(missing))}. Scoring on partial "
                "data would misrepresent confidence."
            ),
        }

    max_importers = max(importer_counts) if importer_counts else 0
    max_coupling = max(couplings) if couplings else 0
    importer_norm = min(max_importers / 10.0, 1.0)
    coupling_norm = min(max_coupling / 10.0, 1.0)
    test_norm = 1.0 if any(test_flags) else 0.0
    score = round(
        100 * (importer_norm * 0.4 + test_norm * 0.3 + (1 - coupling_norm) * 0.3)
    )
    return {
        "score": score,
        "unavailable_inputs": [],
        "note": (
            f"importer_count(max={max_importers}) + test_presence"
            f"({any(test_flags)}) + coupling(max={max_coupling}, lower is "
            "easier to extract)"
        ),
    }


def get_embedding_coverage(bin_path: str) -> dict:
    result = run_almanac(bin_path, ["coverage"])
    if result["ok"] and isinstance(result["data"], dict):
        pct = _first(result["data"], "embedding_coverage_pct", "semantic_coverage_pct")
        if pct is not None:
            return {"pct": pct, "as_of": "live", "source": "almanac coverage"}
    return {
        "pct": FALLBACK_EMBEDDING_COVERAGE_PCT,
        "as_of": FALLBACK_EMBEDDING_COVERAGE_ASOF,
        "source": "fallback (last measured, almanac coverage unavailable live)",
    }


def build_report(concept: str, limit: int, fixture: Path, bin_path: str) -> dict:
    loaded = load_sites(concept, limit, fixture, bin_path)
    sites = loaded["sites"]
    cache = {}
    if loaded["mode"] != "fixture":
        for s in sites:
            enrich_site(s, bin_path, cache)

    clusters = cluster_by_symbol(sites)
    coverage = get_embedding_coverage(bin_path)

    rows = []
    for c in clusters:
        copies = detect_copies(c)
        copied_site_keys = {k for g in copies for k in g["sites"]}
        rows.append(
            {
                "symbol": c.symbol,
                "site_count": len(c.sites),
                "sites": [
                    {
                        "repo": s.repo,
                        "path": s.path,
                        "line": s.line,
                        "citation": s.key,
                        "flagged_copy": s.key in copied_site_keys,
                    }
                    for s in c.sites
                ],
                "copy_groups": copies,
                "independently_written_count": len(c.sites) - len(copied_site_keys),
                "existing_extraction": find_existing_extraction(c),
                "extractability": score_extractability(c),
            }
        )

    total_copy_sites = sum(
        1 for r in rows for g in r["copy_groups"] for _ in g["sites"]
    )
    # dedupe: a site counted once even if it participates in one group only
    copy_site_total = len({k for r in rows for g in r["copy_groups"] for k in g["sites"]})

    return {
        "concept": concept,
        "retrieval_mode": loaded["mode"],
        "retrieval_note": loaded["note"],
        "vocabulary_warning": (
            "keyword mode only finds shared-vocabulary concepts: this "
            "census groups strictly by exact symbol name and CANNOT see "
            "implementations that solve the same problem under a "
            f"different name. Fleet embedding coverage is {coverage['pct']}% "
            f"(as of {coverage['as_of']}, source: {coverage['source']}) — "
            "until that drains, divergent naming is invisible to this tool."
        ),
        "total_sites": len(sites),
        "total_capabilities": len(rows),
        "total_literal_copy_sites": copy_site_total,
        "capabilities": rows,
    }


def print_human(report: dict) -> None:
    print(f"almanac census — concept: {report['concept']!r}")
    print(f"  retrieval mode: {report['retrieval_mode']} — {report['retrieval_note']}")
    print(f"  {report['total_sites']} sites across {report['total_capabilities']} capabilities, "
          f"{report['total_literal_copy_sites']} flagged as literal copies")
    print(f"  WARNING: {report['vocabulary_warning']}")
    print()
    for row in report["capabilities"]:
        print(f"[{row['symbol']}] {row['site_count']} site(s)")
        for s in row["sites"]:
            flag = " (COPY)" if s["flagged_copy"] else ""
            print(f"    {s['citation']}{flag}")
        for g in row["copy_groups"]:
            print(f"    -> copy group ({g['tier']}): {', '.join(g['sites'])}")
        if row["existing_extraction"]:
            print(f"    EXISTING EXTRACTION: {row['existing_extraction']['message']}")
        ex = row["extractability"]
        if ex["score"] is None:
            print(f"    extractability: unscored — {ex['note']}")
        else:
            print(f"    extractability: {ex['score']}/100 — {ex['note']}")
        print()


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("concept", help="the capability to census, e.g. 'retry exponential backoff'")
    ap.add_argument("--limit", type=int, default=DEFAULT_LIMIT)
    ap.add_argument("--fixture", type=Path, default=None, help="load sites from a JSON fixture instead of a live almanac call")
    ap.add_argument("--almanac-bin", type=str, default=None)
    ap.add_argument("--json", action="store_true")
    args = ap.parse_args()

    bin_path = almanac_bin(args.almanac_bin)
    report = build_report(args.concept, args.limit, args.fixture, bin_path)

    if args.json:
        print(json.dumps(report, indent=2, sort_keys=True))
    else:
        print_human(report)
    return 0


if __name__ == "__main__":
    sys.exit(main())
