#!/usr/bin/env python3
"""RESILIENT-1114: shared depends_on resolution logic for the gap pickers.

_pick_gap.py (canonical ranking source) and _pick_and_claim_gap.py (atomic
picker+claimer) both need to decide whether a gap's `depends_on` list is
satisfied. Before this module existed, each file carried its own copy of
this logic with a "keep in sync" comment — and they drifted: _pick_gap.py
resolved deps that were all status=done (INFRA-398), while
_pick_and_claim_gap.py coarse-skipped ANY gap with a non-empty depends_on,
falsely marking 47 dep-satisfied gaps as unpickable in production (RESILIENT-1114).

Both pickers should now call `parse_dep_list()` + `unresolved_deps()` from
here instead of reimplementing the logic.
"""

from __future__ import annotations

import json


class MalformedDepList(Exception):
    """Raised when depends_on is a string that fails to JSON-decode."""


def parse_dep_list(deps_raw: object) -> list[str]:
    """Normalize a gap's raw `depends_on` field into a list of gap IDs.

    `depends_on` arrives as a JSON-encoded string from `chump gap list
    --json` (e.g. "[]" or '["INFRA-100"]'), but callers may also already
    have a decoded list. Raises MalformedDepList if a non-empty string
    fails to JSON-decode — callers should treat that as "skip to be safe"
    (mirrors the pre-existing behavior in both pickers).
    """
    if isinstance(deps_raw, str):
        if not deps_raw.strip():
            return []
        try:
            return json.loads(deps_raw)
        except json.JSONDecodeError as exc:
            raise MalformedDepList(deps_raw) from exc
    if isinstance(deps_raw, list):
        return deps_raw
    return []


def unresolved_deps(dep_list: list[str], gaps: list[dict], active: set[str]) -> list[str]:
    """Return the subset of dep_list that is neither active nor done.

    INFRA-398: a dependency counts as resolved if it's in `active` (claimed
    by a sibling this cycle) OR its gap row in `gaps` has status=="done".
    An empty return means every dependency is satisfied and the gap stays
    pickable.
    """
    unresolved = [d for d in dep_list if d not in active]
    if not unresolved:
        return unresolved
    for gap in gaps:
        if gap.get("id") in unresolved and gap.get("status") == "done":
            unresolved.remove(gap.get("id"))
    return unresolved
