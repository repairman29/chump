#!/usr/bin/env python3
"""Unit test for compute_summarized_pct (CREDIBLE-352, CREDIBLE-300 slice).

almanac-census.py is hyphenated (matches its sibling CLI scripts in
scripts/dev/), so it can't be `import`ed by name — load it via importlib
from its file path instead.
"""

import importlib.util
import sys
from pathlib import Path

_MODULE_PATH = Path(__file__).parent / "almanac-census.py"
_spec = importlib.util.spec_from_file_location("almanac_census", _MODULE_PATH)
almanac_census = importlib.util.module_from_spec(_spec)
sys.modules["almanac_census"] = almanac_census
_spec.loader.exec_module(almanac_census)

Site = almanac_census.Site
compute_summarized_pct = almanac_census.compute_summarized_pct


def _sample_sites():
    # Deterministic 4-site sample: 3 summarized, 1 not -> 0.75.
    return [
        Site(repo="repoA", path="src/a.py", line=1, symbol="Foo", summarized=True),
        Site(repo="repoB", path="src/b.py", line=2, symbol="Foo", summarized=True),
        Site(repo="repoC", path="src/c.py", line=3, symbol="Foo", summarized=True),
        Site(repo="repoD", path="src/d.py", line=4, symbol="Foo", summarized=False),
    ]


def test_compute_summarized_pct():
    sites = _sample_sites()
    pct = compute_summarized_pct(sites)
    assert pct == 0.75, f"expected 0.75, got {pct}"


def test_compute_summarized_pct_empty():
    assert compute_summarized_pct([]) == 0.0


def test_compute_summarized_pct_unset_counts_as_not_summarized():
    sites = [Site(repo="r", path="p", line=1, symbol="Foo")]
    assert compute_summarized_pct(sites) == 0.0


if __name__ == "__main__":
    test_compute_summarized_pct()
    test_compute_summarized_pct_empty()
    test_compute_summarized_pct_unset_counts_as_not_summarized()
    print("OK")
