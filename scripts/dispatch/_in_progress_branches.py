#!/usr/bin/env python3
"""RESILIENT-1509: filter remote chump/* branches down to genuinely
in-progress gaps.

worker.sh's RESILIENT-332 anti-spin layer excludes any gap with a pushed
`chump/<gapid>-fleet-*` branch on origin from the picker, on the theory that
a pushed branch means a PR is in flight. That broke down when 1,437 dead
`wip/*`-style branches accumulated on origin (crashed workers, abandoned
claims): ~91 open gaps whose ONLY blocker was a stale leftover branch (no
open PR, no commit activity in days) sat permanently unpickable even though
they were genuinely free to work.

A branch is a real in-progress signal only when it has an open PR OR recent
commit activity. Dead branches with neither must not block the gap forever.

Reads tab-separated rows from stdin: "<gap_id>\t<commit_epoch>\t<has_open_pr>"
  - commit_epoch: unix timestamp of the branch tip's last commit, or 0/empty
    when unknown (treated as "not recent" — fails safe towards PICKABLE,
    not towards blocking, since an unknown-age branch is far more likely to
    be a long-dead leftover than a brand-new one on this codebase's branch
    naming convention).
  - has_open_pr: "1" if a cache/API lookup found an open PR for this branch,
    else "0"/empty.

Prints each genuinely in-progress gap id (deduped, uppercased), one per line.
"""

from __future__ import annotations

import sys


def is_branch_in_progress(
    commit_ts: int, has_open_pr: bool, now: int, stale_hours: float
) -> bool:
    """True when a branch must still block its gap from being picked."""
    if has_open_pr:
        return True
    if commit_ts <= 0:
        return False
    age_hours = (now - commit_ts) / 3600.0
    return age_hours < stale_hours


def _parse_row(line: str) -> tuple[str, int, bool] | None:
    parts = line.rstrip("\n").split("\t")
    if len(parts) != 3:
        return None
    gap_id = parts[0].strip().upper()
    if not gap_id:
        return None
    try:
        commit_ts = int(parts[1].strip()) if parts[1].strip() else 0
    except ValueError:
        commit_ts = 0
    has_open_pr = parts[2].strip() == "1"
    return gap_id, commit_ts, has_open_pr


def main(argv: list[str]) -> int:
    if len(argv) < 3:
        sys.stderr.write(
            "usage: _in_progress_branches.py <now_epoch> <stale_hours>\n"
        )
        return 1
    now = int(argv[1])
    stale_hours = float(argv[2])

    seen: set[str] = set()
    for line in sys.stdin:
        row = _parse_row(line)
        if row is None:
            continue
        gap_id, commit_ts, has_open_pr = row
        if gap_id in seen:
            continue
        if is_branch_in_progress(commit_ts, has_open_pr, now, stale_hours):
            seen.add(gap_id)
            print(gap_id)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
