#!/usr/bin/env python3
"""almanac-zero-hits.py — EFFECTIVE-380

Mines almanac's own usage telemetry (`~/.almanac/usage.jsonl`, schema owned by
`crates/almanac-core/src/usage.rs` in the repairman29/almanac repo) for its
zero-hit queries: questions the fleet actually asked, in its own words, that
the index could not answer. That log has never been read before this — it is
a free, real-usage capability backlog, but only if the raw lines are turned
into a short ranked list of THEMES instead of a wall of one-off queries, and
only if the three causes behind a zero-hit are told apart:

  1. absent             — the content genuinely is not in the fleet
  2. retrieval-miss      — the content exists but the query didn't find it
                            (a quality bug in almanac, not a coverage gap)
  3. unsupported-artifact — the query names a class almanac deliberately does
                            not index yet (SQL: INFRA-3530; C/Swift/Kotlin/
                            Ruby/Java source: CREDIBLE-210)

Those three need completely different fixes, and lumping them into one raw
dump is why the log has sat unread since it started shipping (2026-08-04).

This script is chump-side, not almanac-side: the almanac CLI/binary itself
lives in the separate repairman29/almanac repo, which is not checked out in
every chump worktree (and wasn't in the one this was written from). The log
format is a stable, documented, append-only JSONL contract
(`UsageRecord` in almanac-core/src/usage.rs) that any consumer can read
without the almanac binary being present — so chump mines it directly. A
verification pass (git-grep against this checkout) additionally proves that
at least one flagged retrieval-miss really is a quality bug, not absence.

Usage:
    python3 scripts/dev/almanac-zero-hits.py [--log PATH] [--days N]
                                              [--top N] [--json]
                                              [--similarity F]

Exit code is always 0 — this is a signal for a human/cron to triage into
gaps (MISSION-045: "signals are not work"), not an enforcement gate.
"""

import argparse
import json
import re
import subprocess
import sys
from collections import Counter
from dataclasses import dataclass, field
from datetime import datetime, timedelta, timezone
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent.parent
DEFAULT_LOG = Path.home() / ".almanac" / "usage.jsonl"
DEFAULT_DAYS = 90
DEFAULT_TOP = 15
DEFAULT_SIMILARITY = 0.4

STOPWORDS = {
    "a", "an", "the", "is", "are", "does", "do", "did", "how", "what",
    "where", "when", "why", "which", "who", "in", "of", "to", "for", "on",
    "with", "this", "that", "and", "or", "can", "i", "we", "you", "it",
    "its", "there", "any", "has", "have", "be", "not", "no", "as", "at",
    "from", "by", "if", "into", "our", "vs", "-", "us",
}

SQL_PATTERN = re.compile(
    r"\b(sql|rls|migration|postgres|supabase\s+schema|create\s+table|"
    r"alter\s+table|row\s+level\s+security)\b|\.sql\b",
    re.IGNORECASE,
)
UNSUPPORTED_LANG_PATTERN = re.compile(
    r"\.(swift|kt|kts|cpp|rb|java)\b|\.(c|h)\b|\bswift\b|\bkotlin\b|\bruby\b",
    re.IGNORECASE,
)

CAUSE_ABSENT = "absent"
CAUSE_RETRIEVAL_MISS = "retrieval-miss"
CAUSE_UNSUPPORTED = "unsupported-artifact"


@dataclass
class UsageRecord:
    ts: str
    surface: str
    tool: str
    repo: str
    query: str
    hits: int
    mode: str
    duration_ms: int


@dataclass
class Cluster:
    tokens: set
    records: list = field(default_factory=list)

    @property
    def representative(self) -> str:
        # Shortest raw query reads best as a theme label.
        return min((r.query for r in self.records), key=len)

    @property
    def count(self) -> int:
        return len(self.records)


def load_records(path: Path, days: int) -> list:
    if not path.is_file():
        return []
    cutoff = datetime.now(timezone.utc) - timedelta(days=days)
    out = []
    with open(path, encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                raw = json.loads(line)
            except json.JSONDecodeError:
                continue  # a corrupt line never poisons the report
            try:
                ts = datetime.fromisoformat(raw["ts"].replace("Z", "+00:00"))
            except (KeyError, ValueError):
                continue
            if ts < cutoff:
                continue
            out.append(
                UsageRecord(
                    ts=raw.get("ts", ""),
                    surface=raw.get("surface", ""),
                    tool=raw.get("tool", ""),
                    repo=raw.get("repo") or "",
                    query=raw.get("query", ""),
                    hits=int(raw.get("hits", 0)),
                    mode=raw.get("mode") or "",
                    duration_ms=int(raw.get("duration_ms", 0)),
                )
            )
    return out


def tokenize(query: str) -> set:
    words = re.findall(r"[a-z0-9_.]+", query.lower())
    return {w for w in words if w not in STOPWORDS and len(w) >= 3}


def jaccard(a: set, b: set) -> float:
    if not a or not b:
        return 0.0
    inter = len(a & b)
    union = len(a | b)
    return inter / union if union else 0.0


def cluster_records(records: list, similarity: float) -> list:
    clusters: list = []
    for rec in records:
        tokens = tokenize(rec.query)
        if not tokens:
            tokens = {rec.query.strip().lower() or "(empty query)"}
        best = None
        best_score = 0.0
        for c in clusters:
            score = jaccard(tokens, c.tokens)
            if score > best_score:
                best, best_score = c, score
        if best is not None and best_score >= similarity:
            best.records.append(rec)
        else:
            clusters.append(Cluster(tokens=tokens, records=[rec]))
    clusters.sort(key=lambda c: c.count, reverse=True)
    return clusters


def _grep_files(term: str) -> set:
    try:
        out = subprocess.run(
            ["git", "-C", str(REPO_ROOT), "grep", "-lwiI", "-e", term,
             "--", "*.rs", "*.md", "*.sh", "*.py"],
            capture_output=True,
            text=True,
            timeout=10,
            check=False,
        )
    except (subprocess.TimeoutExpired, OSError):
        return set()
    return {ln for ln in out.stdout.splitlines() if ln.strip()}


PROXIMITY_WINDOW = 6  # lines


def _line_numbers(term: str, fname: str) -> list:
    try:
        out = subprocess.run(
            ["git", "-C", str(REPO_ROOT), "grep", "-nwiI", "-e", term, "--", fname],
            capture_output=True,
            text=True,
            timeout=10,
            check=False,
        )
    except (subprocess.TimeoutExpired, OSError):
        return []
    # git grep output is "path:lineno:content" — split on ":" twice, the
    # line number is the SECOND field, not the first (that's the path).
    nums = []
    for ln in out.stdout.splitlines():
        parts = ln.split(":", 2)
        if len(parts) >= 2 and parts[1].isdigit():
            nums.append(int(parts[1]))
    return nums


def git_grep_evidence(tokens: set, limit: int = 2) -> list:
    """Best-effort proof-of-existence: does this checkout contain content
    matching this cluster's QUERY (not just any one of its words)? Only
    meaningful for repo == chump (or unset, the common case since almanac is
    mostly dogfooded on this repo); other repos can't be verified from this
    checkout and are left unproven.

    A large multi-domain repo makes "two words in the same FILE" a weak bar
    — common words share files by coincidence constantly. Require the two
    distinctive tokens to land within PROXIMITY_WINDOW lines of each other
    (same paragraph/comment block/function), which coincidence rarely
    survives.
    """
    # Deterministic order: `tokens` is a set (hash-randomized iteration), so
    # break length ties alphabetically — otherwise which candidates get
    # tried, and therefore the verdict, would vary run to run.
    candidates = sorted(
        (t for t in tokens if len(t) >= 4), key=lambda t: (-len(t), t)
    )[:4]
    if len(candidates) < 2:
        return []
    file_sets = {t: _grep_files(t) for t in candidates}
    evidence = []
    files_checked = 0
    max_files_checked = 200  # cost cap, not a relevance cap — see below
    for i, t1 in enumerate(candidates):
        for t2 in candidates[i + 1:]:
            # No relevance-based slice here: a fixed prefix of a *sorted*
            # file set means alphabetically-early directories (docs/, .claude/)
            # always shadow later ones (src/) — the exact file most likely to
            # hold real code never gets checked. Bound total git-grep calls
            # instead so cost stays flat regardless of corpus size.
            # Code first, then docs/scripts, alphabetical within each — code
            # is the ground truth for "does this exist", docs paraphrase it.
            common = sorted(
                file_sets[t1] & file_sets[t2],
                key=lambda f: (0 if f.endswith(".rs") else 1, f),
            )
            for fname in common:
                files_checked += 1
                if files_checked > max_files_checked:
                    return evidence
                l1 = _line_numbers(t1, fname)
                l2 = _line_numbers(t2, fname)
                hit = next(
                    (
                        (a, b)
                        for a in l1
                        for b in l2
                        if abs(a - b) <= PROXIMITY_WINDOW
                    ),
                    None,
                )
                if hit:
                    lo, hi = sorted(hit)
                    evidence.append(
                        f"{fname}:{lo}-{hi}: '{t1}' and '{t2}' co-occur "
                        f"within {PROXIMITY_WINDOW} lines"
                    )
                    if len(evidence) >= limit:
                        return evidence
    return evidence


def classify(cluster: Cluster) -> dict:
    sample_text = " ".join(r.query for r in cluster.records)

    if SQL_PATTERN.search(sample_text):
        return {
            "cause": CAUSE_UNSUPPORTED,
            "method": (
                "regex match on SQL-shaped terms (sql/rls/migration/"
                "postgres/create table/…) — almanac never indexes SQL "
                "(INFRA-3530, deliberate deferral, not a bug)"
            ),
            "evidence": [],
        }
    if UNSUPPORTED_LANG_PATTERN.search(sample_text):
        return {
            "cause": CAUSE_UNSUPPORTED,
            "method": (
                "regex match on an unsupported source-language extension "
                "(swift/kt/c/h/cpp/rb/java) — ast-crawler's is_supported() "
                "does not cover these yet (CREDIBLE-210 class)"
            ),
            "evidence": [],
        }

    local_repos = {"", "chump"}
    verifiable = any(r.repo in local_repos for r in cluster.records)
    evidence = git_grep_evidence(cluster.tokens) if verifiable else []
    if evidence:
        return {
            "cause": CAUSE_RETRIEVAL_MISS,
            "method": (
                "git grep on this checkout found >= 2 of the cluster's "
                "distinctive query tokens within "
                f"{PROXIMITY_WINDOW} lines of each other — the content "
                "exists, so the zero-hit is a retrieval quality bug, not "
                "absence"
            ),
            "evidence": evidence,
        }

    reason = (
        "no git-grep evidence in this checkout"
        if verifiable
        else "query's repo is not this checkout — cannot verify locally, "
             "defaulting to absent rather than guessing"
    )
    return {
        "cause": CAUSE_ABSENT,
        "method": (
            f"no SQL/unsupported-language pattern matched and {reason}; "
            "treated as content genuinely missing from the fleet unless a "
            "human spots evidence this script couldn't reach"
        ),
        "evidence": [],
    }


def build_report(records: list, top: int, similarity: float) -> dict:
    zero_hits = [r for r in records if r.hits == 0]
    clusters = cluster_records(zero_hits, similarity)
    themes = []
    for c in clusters[:top]:
        verdict = classify(c)
        themes.append(
            {
                "theme": c.representative,
                "count": c.count,
                "example_queries": sorted({r.query for r in c.records})[:5],
                "cause": verdict["cause"],
                "classification_method": verdict["method"],
                "evidence": verdict["evidence"],
            }
        )
    by_cause = Counter(t["cause"] for t in themes)
    return {
        "total_calls": len(records),
        "zero_hit_calls": len(zero_hits),
        "zero_hit_rate": (
            round(len(zero_hits) / len(records), 4) if records else 0.0
        ),
        "cluster_count": len(clusters),
        "themes_shown": len(themes),
        "themes_by_cause": dict(by_cause),
        "themes": themes,
    }


def print_human(report: dict, log_path: Path) -> None:
    print(f"almanac zero-hit mining — {log_path}")
    print(
        f"  {report['total_calls']} calls, {report['zero_hit_calls']} "
        f"zero-hit ({report['zero_hit_rate']:.1%}), "
        f"{report['cluster_count']} distinct themes, "
        f"showing top {report['themes_shown']}"
    )
    if not report["themes"]:
        print("  (no zero-hit records in window — nothing to mine)")
        return
    print(f"  by cause: {report['themes_by_cause']}")
    print()
    for i, t in enumerate(report["themes"], 1):
        print(f"{i}. [{t['cause']}] \"{t['theme']}\"  (x{t['count']})")
        print(f"   method: {t['classification_method']}")
        for q in t["example_queries"][:3]:
            print(f"   - {q!r}")
        for e in t["evidence"]:
            print(f"   evidence: {e}")
        print()


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--log", type=Path, default=DEFAULT_LOG)
    ap.add_argument("--days", type=int, default=DEFAULT_DAYS)
    ap.add_argument("--top", type=int, default=DEFAULT_TOP)
    ap.add_argument("--similarity", type=float, default=DEFAULT_SIMILARITY)
    ap.add_argument("--json", action="store_true")
    ap.add_argument(
        "--zero-hits",
        action="store_true",
        help="no-op flag kept for symmetry with the almanac CLI's own "
             "'usage --zero-hits' spelling; this script only ever reports "
             "zero-hits",
    )
    args = ap.parse_args()

    records = load_records(args.log, args.days)
    report = build_report(records, args.top, args.similarity)

    if args.json:
        print(json.dumps(report, indent=2, sort_keys=True))
    else:
        print_human(report, args.log)
    return 0


if __name__ == "__main__":
    sys.exit(main())
