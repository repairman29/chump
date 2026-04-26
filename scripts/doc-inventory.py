#!/usr/bin/env python3.12
"""
DOC-005 / Phase 1 — doc inventory.

Walks top-level docs/*.md, reads YAML front-matter (if present), counts
inbound references across the repo, and writes docs/_inventory.csv.

Run from the repo root:

    python3.12 scripts/doc-inventory.py [--out docs/_inventory.csv]

Subsequent runs overwrite the CSV. Diff against the committed copy to spot
drift (new untagged file, doc that lost all inbound refs, etc.).

Phase scope (per docs/DOC_HYGIENE_PLAN.md):
- Top-level docs/*.md only. Subdirectory docs/{eval,rfcs,archive,...}/ have
  implicit classification via path and are out of scope here.
- Tolerates missing front-matter — writes tag="untagged".
- Inbound-ref count grepped across docs/, book/src/, src/, scripts/,
  .github/, tests/. Excludes self-references, .claude/worktrees/, target/,
  docs-site/, and book/book/.
"""

from __future__ import annotations

import argparse
import csv
import os
import re
import subprocess
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent

# Search roots for inbound references.
SEARCH_ROOTS = ["docs", "book/src", "src", "scripts", ".github", "tests", "AGENTS.md", "CLAUDE.md", "README.md"]

# Directories to exclude when counting inbound refs.
EXCLUDE_DIRS = {".claude", "target", "docs-site", "book/book", "node_modules", ".git"}

# Recognized doc_tag values (per docs/DOC_HYGIENE_PLAN.md Phase 0).
VALID_TAGS = {
    "canonical",
    "decision-record",
    "runbook",
    "log",
    "redirect",
    "archive-candidate",
    "untagged",
}

FRONT_MATTER_RE = re.compile(r"\A---\s*\n(.*?)\n---\s*\n", re.DOTALL)


def parse_front_matter(text: str) -> dict[str, str]:
    """Minimal YAML-ish parser — single-line key:value pairs only.

    Avoids a PyYAML dep. Front-matter we write is always single-line scalars,
    so this is sufficient. If a doc happens to ship multi-line YAML we'll
    only pick up the keys we know about.
    """
    m = FRONT_MATTER_RE.match(text)
    if not m:
        return {}
    body = m.group(1)
    out: dict[str, str] = {}
    for line in body.splitlines():
        if ":" not in line:
            continue
        key, _, value = line.partition(":")
        out[key.strip()] = value.strip().strip('"').strip("'")
    return out


def last_modified(path: Path) -> str:
    """ISO-8601 timestamp of the file's most recent commit, or '' if untracked."""
    try:
        result = subprocess.run(
            ["git", "log", "-1", "--format=%cI", "--", str(path.relative_to(REPO_ROOT))],
            capture_output=True,
            text=True,
            cwd=REPO_ROOT,
            check=False,
        )
        return result.stdout.strip()
    except Exception:
        return ""


def count_inbound_refs(doc_basename: str, self_path: Path) -> int:
    """Count files (excluding the doc itself) that mention `doc_basename`.

    `doc_basename` is the file's stem (e.g. "ROADMAP" for "ROADMAP.md") so we
    catch both "ROADMAP.md" and bare "ROADMAP" mentions. Uses ripgrep when
    available for speed; falls back to grep -r.
    """
    self_rel = str(self_path.relative_to(REPO_ROOT))
    excludes = []
    for d in EXCLUDE_DIRS:
        excludes.extend(["--exclude-dir", d])

    rg_path = subprocess.run(["which", "rg"], capture_output=True, text=True).stdout.strip()
    if rg_path:
        cmd = ["rg", "--files-with-matches", "--no-messages"]
        for d in EXCLUDE_DIRS:
            cmd.extend(["--glob", f"!**/{d}/**"])
        cmd.extend([doc_basename, *[str(REPO_ROOT / r) for r in SEARCH_ROOTS if (REPO_ROOT / r).exists()]])
    else:
        cmd = ["grep", "-rl", *excludes, doc_basename]
        cmd.extend([str(REPO_ROOT / r) for r in SEARCH_ROOTS if (REPO_ROOT / r).exists()])

    result = subprocess.run(cmd, capture_output=True, text=True, check=False)
    files = [f for f in result.stdout.splitlines() if f and f != str(REPO_ROOT / self_rel)]
    return len(files)


def line_count(path: Path) -> int:
    try:
        with path.open("rb") as f:
            return sum(1 for _ in f)
    except OSError:
        return 0


def collect() -> list[dict[str, str | int]]:
    docs_root = REPO_ROOT / "docs"
    rows: list[dict[str, str | int]] = []
    for entry in sorted(docs_root.iterdir()):
        if not entry.is_file() or entry.suffix != ".md":
            continue
        text = entry.read_text(errors="replace")
        fm = parse_front_matter(text)
        tag = fm.get("doc_tag", "untagged")
        if tag not in VALID_TAGS:
            tag = f"invalid:{tag}"
        rows.append(
            {
                "path": str(entry.relative_to(REPO_ROOT)),
                "tag": tag,
                "owner_gap": fm.get("owner_gap", ""),
                "last_modified": last_modified(entry),
                "inbound_refs": count_inbound_refs(entry.stem, entry),
                "line_count": line_count(entry),
                "last_audited": fm.get("last_audited", ""),
            }
        )
    return rows


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--out",
        default=str(REPO_ROOT / "docs" / "_inventory.csv"),
        help="Output CSV path (default: docs/_inventory.csv)",
    )
    args = parser.parse_args()

    rows = collect()

    out_path = Path(args.out)
    out_path.parent.mkdir(parents=True, exist_ok=True)
    with out_path.open("w", newline="") as f:
        fieldnames = ["path", "tag", "owner_gap", "last_modified", "inbound_refs", "line_count", "last_audited"]
        writer = csv.DictWriter(f, fieldnames=fieldnames)
        writer.writeheader()
        for row in rows:
            writer.writerow(row)

    untagged = sum(1 for r in rows if r["tag"] == "untagged")
    invalid = sum(1 for r in rows if isinstance(r["tag"], str) and r["tag"].startswith("invalid:"))
    orphans = sum(1 for r in rows if r["inbound_refs"] == 0)
    print(f"docs inventory: {len(rows)} files → {out_path}", file=sys.stderr)
    print(f"  untagged: {untagged}", file=sys.stderr)
    if invalid:
        print(f"  invalid tags: {invalid}", file=sys.stderr)
    print(f"  zero inbound refs (orphan candidates): {orphans}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
