#!/usr/bin/env python3
"""
mdBook link checker (lightweight, no external deps).

Scans generated HTML under docs-site/ for relative href/src targets that don't exist.
Intentionally ignores:
- absolute URLs (http:, https:)
- anchors (#...)
- mailto:
- javascript:

Exit 1 when missing targets are found.
"""

from __future__ import annotations

import os
import re
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SITE = ROOT / "docs-site"


HREF_RE = re.compile(r"""(?P<attr>href|src)\s*=\s*["'](?P<val>[^"']+)["']""")


def is_ignored(url: str) -> bool:
    u = url.strip()
    if not u:
        return True
    if u.startswith("#"):
        return True
    if u.startswith(("http://", "https://", "mailto:", "javascript:")):
        return True
    # Data URLs are rare in the book output; ignore them.
    if u.startswith("data:"):
        return True
    return False


def split_anchor(url: str) -> str:
    # Remove fragment part for filesystem existence checks.
    return url.split("#", 1)[0]


def main() -> int:
    if not SITE.is_dir():
        print(f"[mdbook-linkcheck] ERROR: docs-site/ not found at {SITE}", file=sys.stderr)
        return 2

    html_files = sorted(SITE.rglob("*.html"))
    if not html_files:
        print("[mdbook-linkcheck] ERROR: no *.html files found under docs-site/", file=sys.stderr)
        return 2

    missing: list[tuple[Path, str, Path]] = []

    for html_path in html_files:
        try:
            body = html_path.read_text(encoding="utf-8", errors="replace")
        except Exception as e:
            print(f"[mdbook-linkcheck] WARN: could not read {html_path}: {e}", file=sys.stderr)
            continue

        for m in HREF_RE.finditer(body):
            raw = m.group("val")
            if is_ignored(raw):
                continue
            target = split_anchor(raw)
            if not target:
                continue
            # mdBook output uses site-relative links like "foo.html" or "../bar.html".
            resolved = (html_path.parent / target).resolve()

            # Only treat targets inside docs-site/ as checkable. If the resolved path escapes,
            # it's almost certainly a broken "book-escaping" link and should fail.
            try:
                resolved.relative_to(SITE.resolve())
            except Exception:
                missing.append((html_path, raw, resolved))
                continue

            if not resolved.exists():
                missing.append((html_path, raw, resolved))

    if missing:
        print(f"[mdbook-linkcheck] FAIL: {len(missing)} broken relative href/src targets", file=sys.stderr)
        # Print a capped sample; CI logs should remain readable.
        cap = 80
        for (src_html, raw, resolved) in missing[:cap]:
            rel = src_html.relative_to(SITE)
            print(f"  - {rel}: {raw} -> {resolved}", file=sys.stderr)
        if len(missing) > cap:
            print(f"  ... {len(missing) - cap} more", file=sys.stderr)
        return 1

    print("[mdbook-linkcheck] OK: no broken relative links found")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

