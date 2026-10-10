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


# ─────────────────────────────────────────────────────────────────────────────
# Canonical pickability status sets (single source of truth).
#
# These used to be duplicated verbatim in BOTH _pick_gap.py and
# _pick_and_claim_gap.py (and sat UNUSED there). They live HERE now — the shared
# module both pickers already import — so the "is this status still open work?"
# judgment has exactly one definition and cannot drift (the whole reason
# RESILIENT-1114 created this module). The pickers import them from here.
#
#   PICKABLE_STATUSES  : a gap in one of these is genuine, un-shipped open work.
#   _DONE_LIKE_STATUSES: every status meaning "NOT fresh pickable work" — done,
#       shipped, superseded, closed, duplicate, blocked, in-flight, etc. A
#       dependency in any of these no longer gates its dependents (see
#       unresolved_deps below).
PICKABLE_STATUSES = {"open", "ready"}
_DONE_LIKE_STATUSES = {
    "already_satisfied", "done", "shipped", "superseded", "closed",
    "closed_not_a_bug", "duplicate", "wont_fix", "wontfix", "blocked",
    "in_progress", "in-progress", "in_review", "in_flight", "perpetual",
    "ready_to_ship",
}


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
    """Return the subset of dep_list that still gates the dependent gap.

    A dependency is RESOLVED (no longer gates) when ANY of:
      * it is in `active` — claimed by a sibling worker this cycle (INFRA-398);
      * its gap row in `gaps` has a terminal / done-like status
        (``_DONE_LIKE_STATUSES`` — done, shipped, superseded, closed, duplicate,
        blocked, in-flight, etc.). The old logic resolved ONLY status=="done",
        so superseded/closed/already_satisfied dep-edges (observed: ~1,142 of
        them) falsely pinned ~456 otherwise-pickable gaps shut and workers
        starved on ghosts instead of real candidates;
      * it does NOT exist in `gaps` — a dangling / nonexistent dep ID (a typo,
        or a dep whose gap was hard-deleted/consolidated away) can never be
        satisfied, so treating it as unresolved would wedge the dependent
        forever. A dep we cannot find is treated as resolved, not a permanent
        block.

    A dependency is UNRESOLVED only when it EXISTS, is NOT active, and its status
    is still genuine open work (anything not in ``_DONE_LIKE_STATUSES`` — e.g.
    open / ready, or an unknown status we cannot vouch for, which stays gating to
    be safe). An empty return means every dependency is satisfied and the gap
    stays pickable.
    """
    candidates = [d for d in dep_list if d not in active]
    if not candidates:
        return []
    status_by_id = {
        g.get("id"): (g.get("status") or "").strip().lower() for g in gaps
    }
    unresolved: list[str] = []
    for dep in candidates:
        if dep not in status_by_id:
            continue  # dangling / nonexistent dep ID → cannot gate; resolved
        if status_by_id[dep] in _DONE_LIKE_STATUSES:
            continue  # terminal / not-fresh-work → satisfied
        unresolved.append(dep)
    return unresolved
