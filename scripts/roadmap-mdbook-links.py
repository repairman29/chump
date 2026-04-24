#!/usr/bin/env python3
"""
Rewrite relative markdown targets in docs/ROADMAP.md for mdBook + GitHub Pages.

- In-nav mdBook chapters -> same-directory ./chapter.md (lowercase names).
- docs/rfcs/* -> GitHub blob under docs/rfcs/.
- templates/* -> GitHub blob under templates/.
- Merged mistral matrix / agent-power / benchmarks -> docs/MISTRALRS.md blob.
- Other *.md in docs/ or repo root -> GitHub blob when the file exists.
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
ROADMAP = ROOT / "docs" / "ROADMAP.md"
BASE = "https://github.com/repairman29/chump/blob/main"

# Published mdBook chapters live at site root; map common doc filenames -> href.
BOOK_LOCAL = {
    "introduction.md": "./introduction.md",
    "dissertation.md": "./dissertation.md",
    "getting-started.md": "./getting-started.md",
    "EXTERNAL_GOLDEN_PATH.md": "./getting-started.md",
    "operations.md": "./operations.md",
    "OPERATIONS.md": "./operations.md",
    "architecture.md": "./architecture.md",
    "rust-infrastructure.md": "./rust-infrastructure.md",
    "RUST_INFRASTRUCTURE.md": "./rust-infrastructure.md",
    "metrics.md": "./metrics.md",
    "METRICS.md": "./metrics.md",
    "chump-to-complex.md": "./chump-to-complex.md",
    "CHUMP_TO_COMPLEX.md": "./chump-to-complex.md",
    "research-paper.md": "./research-paper.md",
    "findings.md": "./findings.md",
    "research-community.md": "./research-community.md",
    "RESEARCH_COMMUNITY.md": "./research-community.md",
    "research-integrity.md": "./research-integrity.md",
    "RESEARCH_INTEGRITY.md": "./research-integrity.md",
    "oops.md": "./oops.md",
    "OOPS.md": "./oops.md",
    "roadmap.md": "./roadmap.md",
    "ROADMAP.md": "./roadmap.md",
}

MISTRAL_MERGED = {
    "MISTRALRS_CAPABILITY_MATRIX.md": f"{BASE}/docs/MISTRALRS.md",
    "MISTRALRS_AGENT_POWER_PATH.md": f"{BASE}/docs/MISTRALRS.md",
    "MISTRALRS_BENCHMARKS.md": f"{BASE}/docs/MISTRALRS.md",
}


def rewrite_target(raw: str) -> str | None:
    if raw.startswith(("http://", "https://", "mailto:")):
        return None
    if raw.startswith("#"):
        return None
    if raw.startswith(("./", "../")):
        return None

    if "#" in raw:
        base, frag = raw.split("#", 1)
        anchor = "#" + frag
    else:
        base, anchor = raw, ""

    if base in MISTRAL_MERGED:
        return MISTRAL_MERGED[base] + anchor

    basename = Path(base).name
    if base == basename and basename in BOOK_LOCAL:
        return BOOK_LOCAL[basename] + anchor

    if base.startswith("rfcs/"):
        return f"{BASE}/docs/{base}" + anchor

    if base.startswith("templates/"):
        return f"{BASE}/{base}" + anchor

    if base.startswith("docs/"):
        return f"{BASE}/{base}" + anchor

    if re.match(r"^ADR-[0-9]", basename) and (ROOT / "docs" / basename).is_file():
        return f"{BASE}/docs/{basename}" + anchor

    if base == basename and basename.endswith(".md"):
        if (ROOT / "docs" / basename).is_file():
            return f"{BASE}/docs/{basename}" + anchor
        if (ROOT / basename).is_file():
            return f"{BASE}/{basename}" + anchor
        # Orphan names still break mdBook relative resolution; pin to canonical docs/ URL.
        return f"{BASE}/docs/{basename}" + anchor

    return None


LINK_RE = re.compile(r"\[([^\]]*)\]\(([^)]+)\)")


def transform(text: str) -> tuple[str, int]:
    changes = 0

    def repl(m: re.Match[str]) -> str:
        nonlocal changes
        label, target = m.group(1), m.group(2)
        new_t = rewrite_target(target)
        if new_t is None or new_t == target:
            return m.group(0)
        changes += 1
        return f"[{label}]({new_t})"

    return LINK_RE.sub(repl, text), changes


def main() -> int:
    if not ROADMAP.is_file():
        print(f"error: missing {ROADMAP}", file=sys.stderr)
        return 2
    old = ROADMAP.read_text(encoding="utf-8")
    new, n = transform(old)
    if new != old:
        ROADMAP.write_text(new, encoding="utf-8", newline="\n")
    print(f"roadmap-mdbook-links: {n} link target(s) rewritten")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
