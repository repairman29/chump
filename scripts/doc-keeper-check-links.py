#!/usr/bin/env python3
"""Scan Markdown trees for broken relative file links. Prints BROKEN_LINK lines; exit 1 if any."""
from __future__ import annotations

import os
import re
import sys

LINK_RE = re.compile(r"\[[^\]]*\]\(([^)]+)\)")


def target_ok(p: str) -> bool:
    return os.path.exists(p) and (os.path.isfile(p) or os.path.isdir(p))


def scan_file(path: str, root: str) -> list[tuple[str, str, str]]:
    errors: list[tuple[str, str, str]] = []
    try:
        text = open(path, encoding="utf-8", errors="replace").read()
    except OSError as e:
        return [(path, f"<read: {e}>", "")]
    base = os.path.dirname(path)
    for m in LINK_RE.finditer(text):
        raw = m.group(1).strip()
        if not raw or raw.startswith(("#", "http://", "https://", "mailto:")):
            continue
        path_part = raw.split("#", 1)[0].split("?", 1)[0].strip()
        if not path_part or path_part in ("...", ".", ".."):
            continue
        scheme = path_part.split(":", 1)[0]
        if scheme in ("http", "https", "mailto", "ftp", "data", "javascript"):
            continue
        if "/" not in path_part and scheme and not path_part.startswith("."):
            # e.g. npm:package — not a repo path
            if len(scheme) < 20 and path_part == scheme:
                continue
        target = os.path.normpath(os.path.join(base, path_part))
        candidates = [target]
        # Docs often link as scripts/foo or src/foo meaning repo-root paths.
        alt = os.path.normpath(os.path.join(root, path_part))
        if alt != target:
            candidates.append(alt)
        if any(target_ok(c) for c in candidates):
            continue
        errors.append((path, raw, candidates[0]))
    return errors


def main() -> int:
    if len(sys.argv) < 2:
        print(
            "Usage: doc-keeper-check-links.py REPO_ROOT [REL_SUBDIR ...]",
            file=sys.stderr,
        )
        return 2
    root = os.path.abspath(sys.argv[1])
    subdirs = sys.argv[2:] or ["docs"]
    all_errs: list[tuple[str, str, str]] = []
    for sub in subdirs:
        d = os.path.join(root, sub)
        if not os.path.isdir(d):
            continue
        for dirpath, _, files in os.walk(d):
            for f in files:
                if not f.endswith(".md"):
                    continue
                p = os.path.join(dirpath, f)
                all_errs.extend(scan_file(p, root))
    if all_errs:
        for src, raw, tgt in all_errs:
            print(f"BROKEN_LINK\t{src}\t{raw}\t-> {tgt}")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
