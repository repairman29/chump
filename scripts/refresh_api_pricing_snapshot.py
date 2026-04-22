#!/usr/bin/env python3
"""Refresh docs/API_PRICING_SNAPSHOT.md using Tavily search (TAVILY_API_KEY).

Same HTTP contract as crates/mcp-servers/chump-mcp-tavily (Bearer auth).
Does not patch cost_ledger.py — human compares digest to vendor pages first.

Usage (from repo root):
  export TAVILY_API_KEY=tvly-...
  python3 scripts/refresh_api_pricing_snapshot.py docs/API_PRICING_SNAPSHOT.md
"""

from __future__ import annotations

import json
import os
import re
import sys
import urllib.error
import urllib.request
from datetime import datetime, timezone
from pathlib import Path


TAVILY_SEARCH = "https://api.tavily.com/search"

QUERIES: list[tuple[str, str]] = [
    (
        "ANTHROPIC",
        "Anthropic Claude API official pricing dollars per million tokens "
        "Haiku 4.5 Sonnet 4.5 site:docs.anthropic.com OR site:anthropic.com",
    ),
    (
        "TOGETHER",
        "Together AI serverless pricing Llama 3.3 70B Instruct Turbo per million "
        "tokens site:docs.together.ai OR site:together.ai",
    ),
]


def _tavily_search(api_key: str, query: str) -> dict:
    body = json.dumps(
        {
            "query": query,
            "search_depth": "advanced",
            "topic": "general",
            "max_results": 8,
        }
    ).encode("utf-8")
    req = urllib.request.Request(
        TAVILY_SEARCH,
        data=body,
        headers={
            "Authorization": f"Bearer {api_key}",
            "Content-Type": "application/json",
        },
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=60) as resp:
        return json.loads(resp.read().decode("utf-8"))


def _format_digest(label: str, data: dict) -> str:
    lines: list[str] = []
    lines.append(f"_Tavily search digest for **{label}** "
                 f"(UTC {datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')}). "
                 "Verify on the vendor site before editing `cost_ledger.py`._")
    lines.append("")
    answer = data.get("answer")
    if isinstance(answer, str) and answer.strip():
        lines.append("**Summary (model-generated):**")
        lines.append("")
        lines.append(answer.strip())
        lines.append("")
    results = data.get("results")
    if not isinstance(results, list):
        lines.append("_No results array in Tavily response._")
        return "\n".join(lines)
    lines.append("**Top sources:**")
    lines.append("")
    for i, r in enumerate(results[:8], 1):
        if not isinstance(r, dict):
            continue
        title = (r.get("title") or "").strip() or "(no title)"
        url = (r.get("url") or "").strip() or "(no url)"
        content = (r.get("content") or "").strip()
        if len(content) > 650:
            content = content[:647] + "…"
        lines.append(f"{i}. **{title}** — {url}")
        if content:
            lines.append(f"   - _Snippet:_ {content}")
        lines.append("")
    return "\n".join(lines).rstrip() + "\n"


def _replace_region(text: str, start: str, end: str, inner: str) -> str:
    if start not in text or end not in text:
        raise SystemExit(f"markers missing: need {start!r} and {end!r} in snapshot file")
    before, rest = text.split(start, 1)
    _, after = rest.split(end, 1)
    return before + start + "\n" + inner + end + after


def _patch_table_timestamp(text: str, iso: str) -> str:
    pat = re.compile(
        r"(\|\s\*\*Last refresh \(UTC\)\*\*\s\|\s)([^|]*)(\s\|)",
        re.MULTILINE,
    )
    m = pat.search(text)
    if not m:
        return text
    return pat.sub(r"\1" + iso + r"\3", text, count=1)


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: refresh_api_pricing_snapshot.py <path-to-API_PRICING_SNAPSHOT.md>", file=sys.stderr)
        return 2
    path = sys.argv[1]
    key = os.environ.get("TAVILY_API_KEY", "").strip()
    if not key:
        print("TAVILY_API_KEY not set; nothing to do.", file=sys.stderr)
        return 0

    p = Path(path)
    text = p.read_text(encoding="utf-8")

    iso = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    digests: dict[str, str] = {}
    for marker, query in QUERIES:
        try:
            data = _tavily_search(key, query)
        except urllib.error.HTTPError as exc:
            print(f"Tavily HTTP error for {marker}: {exc}", file=sys.stderr)
            return 1
        except urllib.error.URLError as exc:
            print(f"Tavily network error for {marker}: {exc}", file=sys.stderr)
            return 1
        if data.get("error"):
            print(f"Tavily API error for {marker}: {data.get('error')}", file=sys.stderr)
            return 1
        digests[marker] = _format_digest(marker, data)

    text = _replace_region(
        text,
        "<!-- SNAPSHOT:ANTHROPIC_START -->",
        "<!-- SNAPSHOT:ANTHROPIC_END -->",
        "\n" + digests["ANTHROPIC"] + "\n",
    )
    text = _replace_region(
        text,
        "<!-- SNAPSHOT:TOGETHER_START -->",
        "<!-- SNAPSHOT:TOGETHER_END -->",
        "\n" + digests["TOGETHER"] + "\n",
    )
    text = _patch_table_timestamp(text, iso)
    p.write_text(text, encoding="utf-8")
    print(f"updated {path}")
    print("next: human verifies official URLs, then updates cost_ledger.py if needed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
