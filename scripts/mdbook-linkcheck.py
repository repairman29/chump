#!/usr/bin/env python3
"""
mdBook link checker (lightweight, no external deps).

Scans generated HTML under docs-site/ for a subset of link regressions.

Checks:
- **Book-escaping links (all nav chapters)**: any relative target that resolves
  *outside* docs-site/, for every HTML page derived from `book/src/SUMMARY.md`
  (paths relative to docs-site/, e.g. `chronicles/index.html`, so basenames like
  `index.html` do not collide).
- **Static assets**: missing local assets (css/js/images/fonts) under docs-site/

Ignores:
- missing `*.html` pages for **non-nav** HTML (print, 404, search) — only nav
  chapters are enforced for escape; asset checks still apply site-wide.
- absolute URLs (http:, https:)
- anchors (#...)
- mailto:
- javascript:

Exit 1 when violations are found.
"""

from __future__ import annotations

import os
import re
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SITE = ROOT / "docs-site"
SUMMARY = ROOT / "book" / "src" / "SUMMARY.md"


def _nav_from_summary() -> set[str]:
    if not SUMMARY.is_file():
        print(f"[mdbook-linkcheck] WARN: missing {SUMMARY}", file=sys.stderr)
        return set()
    text = SUMMARY.read_text(encoding="utf-8")
    out: set[str] = set()
    for m in re.finditer(r"\]\(\./([^)]+)\)", text):
        md = m.group(1).split("#", 1)[0].strip()
        if md.endswith(".md"):
            out.add(md[:-3] + ".html")
    return out


HREF_RE = re.compile(r"""(?P<attr>href|src)\s*=\s*["'](?P<val>[^"']+)["']""")


def is_ignored(url: str) -> bool:
    u = url.strip()
    if not u:
        return True
    if u.startswith("#"):
        return True
    # Site-root absolute links are valid in production even if they don't map to
    # a filesystem path (e.g. "/chump/"). Don't treat these as missing files.
    if u.startswith("/"):
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

    focus_rel = _nav_from_summary()
    site_root = SITE.resolve()

    violations: list[tuple[Path, str, Path, str]] = []

    for html_path in html_files:
        try:
            body = html_path.read_text(encoding="utf-8", errors="replace")
        except Exception as e:
            print(f"[mdbook-linkcheck] WARN: could not read {html_path}: {e}", file=sys.stderr)
            continue

        rel_html = html_path.resolve().relative_to(site_root).as_posix()
        check_escape = rel_html in focus_rel

        for m in HREF_RE.finditer(body):
            raw = m.group("val")
            if is_ignored(raw):
                continue
            target = split_anchor(raw)
            if not target:
                continue
            # mdBook output uses site-relative links like "foo.html" or "../bar.html".
            resolved = (html_path.parent / target).resolve()

            # If the resolved path escapes docs-site/ it's a broken "book-escaping" link.
            try:
                resolved.relative_to(site_root)
            except Exception:
                if check_escape:
                    violations.append((html_path, raw, resolved, "escapes-docs-site"))
                continue

            # Only enforce existence for static assets. Missing *.html pages are
            # common on non-nav pages; nav chapters are guarded by escape checks above.
            _, ext = os.path.splitext(target.lower())
            if ext in (".css", ".js", ".png", ".jpg", ".jpeg", ".gif", ".svg", ".webp", ".ico", ".woff", ".woff2"):
                if not resolved.exists():
                    violations.append((html_path, raw, resolved, "missing-asset"))

    if violations:
        print(f"[mdbook-linkcheck] FAIL: {len(violations)} link violations", file=sys.stderr)
        # Print a capped sample; CI logs should remain readable.
        cap = 80
        for (src_html, raw, resolved, kind) in violations[:cap]:
            rel = src_html.relative_to(SITE)
            print(f"  - [{kind}] {rel}: {raw} -> {resolved}", file=sys.stderr)
        if len(violations) > cap:
            print(f"  ... {len(violations) - cap} more", file=sys.stderr)
        return 1

    print("[mdbook-linkcheck] OK: no escape links or missing assets found")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
