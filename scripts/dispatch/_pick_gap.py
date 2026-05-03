#!/usr/bin/env python3
"""INFRA-203: gap picker for run-fleet.sh worker loop.

Reads the open-gap JSON from $GAP_JSON_FILE, applies fleet filters, and
prints the single highest-priority pickable gap ID (or nothing). Kept as a
standalone file so worker.sh doesn't have to inline a complex python heredoc.

Inputs (all env vars):
  GAP_JSON_FILE         path to a file containing `chump gap list --json` output
  FLEET_PRIORITY_FILTER comma-separated, e.g. "P0,P1" (empty = any)
  FLEET_DOMAIN_FILTER   comma-separated, e.g. "INFRA,DOC" (empty = any)
  FLEET_EFFORT_FILTER   comma-separated, e.g. "xs,s,m" (empty = any)
  EXCLUDE_RE            regex; gap IDs matching this are skipped
  ACTIVE_GAPS           whitespace-separated gap IDs already claimed by siblings
  WORKER_INDEX          INFRA-340: 1-based worker index. When N workers boot in
                        the same second and no leases exist yet, every worker
                        sees the same candidate list and pre-fix all returned
                        candidates[0] — N workers all picking the same gap.
                        With WORKER_INDEX set, worker K returns
                        candidates[(K-1) % len(candidates)] so they spread
                        across the top-N gaps. Once leases form ACTIVE_GAPS
                        shrinks the list and the offset still maps each
                        worker to a unique remaining candidate.
  COOLDOWN_DIR          INFRA-361: directory holding rc=1 cooldown records
                        (default $REPO_ROOT/.chump-locks/cooldown). Each
                        record is one JSON file named <GAP-ID>.json with
                        keys gap_id / rc / until / agent / ts. Worker.sh
                        writes them on rc!=0 exits to prevent every
                        worker re-picking the same impossible gap on next
                        cycle (worker 4 hit INFRA-340 6× in 5min pre-fix).
                        Expired records are auto-cleaned each pick.
"""

from __future__ import annotations

import json
import os
import re
import sys
import time

PRIO_RANK = {"P0": 0, "P1": 1, "P2": 2, "P3": 3, "": 9}
EFFORT_RANK = {"xs": 0, "s": 1, "m": 2, "l": 3, "xl": 4, "": 9}


def csv(env_key: str) -> list[str]:
    return [s.strip() for s in os.environ.get(env_key, "").split(",") if s.strip()]


def cooled_down_gaps(cooldown_dir: str) -> set[str]:
    """INFRA-361: gap IDs whose cooldown record is still in the future."""
    if not cooldown_dir or not os.path.isdir(cooldown_dir):
        return set()
    now = int(time.time())
    cooled: set[str] = set()
    for entry in os.listdir(cooldown_dir):
        if not entry.endswith(".json"):
            continue
        path = os.path.join(cooldown_dir, entry)
        try:
            with open(path) as f:
                rec = json.load(f)
        except Exception:
            continue
        gid = rec.get("gap_id") or ""
        until = rec.get("until", 0)
        if not gid:
            continue
        if until > now:
            cooled.add(gid)
        else:
            # Expired — clean up the record so the directory doesn't grow.
            try:
                os.remove(path)
            except OSError:
                pass
    return cooled


def main() -> int:
    gap_file = os.environ.get("GAP_JSON_FILE")
    if not gap_file or not os.path.exists(gap_file):
        return 0
    try:
        with open(gap_file) as f:
            gaps = json.load(f)
    except Exception:
        return 0

    prio_filter = [p.upper() for p in csv("FLEET_PRIORITY_FILTER")]
    domain_filter = [d.lower() for d in csv("FLEET_DOMAIN_FILTER")]
    effort_filter = [e.lower() for e in csv("FLEET_EFFORT_FILTER")]
    exclude_re = re.compile(os.environ.get("EXCLUDE_RE", "^$"))
    active = set(os.environ.get("ACTIVE_GAPS", "").split())
    cooled = cooled_down_gaps(os.environ.get("COOLDOWN_DIR", ""))

    candidates = []
    for g in gaps:
        gid = g.get("id", "")
        if not gid or gid in active:
            continue
        if gid in cooled:
            continue
        if exclude_re.search(gid):
            continue
        # INFRA-397: skip gaps that are not open — the gap list includes done
        # gaps which should never be picked up by fleet workers.
        if g.get("status") != "open":
            continue
        # INFRA-206: skip gaps whose notes start with "SUPERSEDED" — they have
        # been superseded by a more general gap and should never be picked up by
        # fleet workers.  The canonical form is "SUPERSEDED YYYY-MM-DD by ..."
        # as written by convention in docs/gaps/<ID>.yaml notes fields.
        notes = (g.get("notes") or "").lstrip()
        if notes.upper().startswith("SUPERSEDED"):
            continue
        p = (g.get("priority") or "").upper()
        if prio_filter and p not in prio_filter:
            continue
        d = (g.get("domain") or "").lower()
        if domain_filter and d not in domain_filter:
            continue
        e = (g.get("effort") or "").lower()
        if effort_filter and e not in effort_filter:
            continue
        # Conservative: skip gaps with non-empty depends_on.
        # First cut — we don't recursively check whether deps are done.
        deps = g.get("depends_on") or "[]"
        try:
            dep_list = json.loads(deps) if isinstance(deps, str) else deps
            if dep_list:  # non-empty array
                continue
        except (json.JSONDecodeError, TypeError):
            # If depends_on is malformed, skip it to be safe
            continue
        # INFRA-206: skip gaps whose notes start with "SUPERSEDED" — they have
        # been superseded by another gap and should not be auto-picked.
        notes = (g.get("notes") or "").strip()
        if notes.upper().startswith("SUPERSEDED"):
            continue
        candidates.append(
            (
                PRIO_RANK.get(p, 9),
                EFFORT_RANK.get(e, 9),
                g.get("created_at") or 0,
                gid,
            )
        )

    candidates.sort()
    if candidates:
        # INFRA-340: stagger by worker index so simultaneously-booting siblings
        # pick different gaps instead of all colliding on candidates[0].
        try:
            worker_idx = int(os.environ.get("WORKER_INDEX", "1"))
        except ValueError:
            worker_idx = 1
        offset = (max(worker_idx, 1) - 1) % len(candidates)
        print(candidates[offset][3])
    return 0


if __name__ == "__main__":
    sys.exit(main())
