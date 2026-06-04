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
  FLEET_MODEL           worker's model tier, e.g. "haiku", "sonnet", "opus"
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

MISSION-011: mission-directed picker
  CHUMP_ACTIVE_MISSION  active mission outcome ID — gaps linked to this outcome
                        are surfaced BEFORE equal-priority substrate gaps.
                        Falls back to reading ~/.chump/ACTIVE_MISSION (one line).
                        Default: MISSION-010 (self-coordinating fleet / 0→1).
                        Set to empty string "" to disable mission boost.
                        A gap is "mission-linked" when any of the following hold:
                          (a) gap.outcome_id == active_mission_id
                          (b) gap.domain == "MISSION"
                          (c) gap.id == active_mission_id
                          (d) active_mission_id appears verbatim in title, notes,
                              or description (catches "blocks MISSION-010" etc.)
                        Boost mechanism: mission_rank=0 (linked) / 1 (not linked)
                        inserted between planner_rank and prio_rank in the sort
                        tuple. A mission P1 sorts as (..., 0, 1, ...) vs a
                        substrate P1 (..., 1, 1, ...) — mission wins. A mission
                        P1 does NOT override a substrate P0 at the same
                        planner_rank bucket (0+1 > 0+0 when prio is P0 vs P1).
                        See scripts/ci/test-mission-picker.sh for the invariant.
"""

from __future__ import annotations

import json
import os
import re
import sys
import time

PRIO_RANK = {"P0": 0, "P1": 1, "P2": 2, "P3": 3, "": 9}
EFFORT_RANK = {"xs": 0, "s": 1, "m": 2, "l": 3, "xl": 4, "": 9}

# MISSION-011: default active mission outcome when no explicit override is set.
_DEFAULT_ACTIVE_MISSION = "MISSION-010"


def csv(env_key: str) -> list[str]:
    return [s.strip() for s in os.environ.get(env_key, "").split(",") if s.strip()]


def _load_active_mission() -> str:
    """MISSION-011: return the active mission outcome ID.

    Resolution order (first non-empty wins):
      1. CHUMP_ACTIVE_MISSION env var (set to "" to disable boost entirely)
      2. ~/.chump/ACTIVE_MISSION file (one line, e.g. "MISSION-010")
      3. Hard-coded default: MISSION-010

    Returns an empty string when the operator has explicitly disabled the
    mission boost (CHUMP_ACTIVE_MISSION="" or file contains only whitespace).
    """
    env_val = os.environ.get("CHUMP_ACTIVE_MISSION")
    if env_val is not None:
        # Env var present — use it verbatim (including "" to disable).
        return env_val.strip()

    # Try ~/.chump/ACTIVE_MISSION
    mission_file = os.path.expanduser("~/.chump/ACTIVE_MISSION")
    try:
        with open(mission_file) as f:
            val = f.read().strip()
            if val:
                return val
    except OSError:
        pass

    return _DEFAULT_ACTIVE_MISSION


def _is_mission_linked(g: dict, active_mission: str) -> bool:
    """MISSION-011: return True when gap `g` is linked to the active mission.

    A gap is mission-linked when ANY of these hold:
      (a) gap.outcome_id matches active_mission (MISSION-008 Outcome FK)
      (b) gap.domain is "MISSION" (mission-domain gaps are inherently linked)
      (c) gap.id matches active_mission exactly
      (d) active_mission appears verbatim in title, notes, or description
          (catches "this blocks MISSION-010" or "unblocks 0→1 / MISSION-010")

    Returns False when active_mission is empty (boost disabled).
    """
    if not active_mission:
        return False

    # (a) Outcome FK match
    if (g.get("outcome_id") or "").strip() == active_mission:
        return True

    # (b) MISSION domain gaps are always considered mission-linked
    if (g.get("domain") or "").upper() == "MISSION":
        return True

    # (c) Gap IS the active mission outcome itself
    if (g.get("id") or "").strip() == active_mission:
        return True

    # (d) Title / notes / description contain the mission ID verbatim
    needle = active_mission.upper()
    for field in ("title", "notes", "description"):
        val = (g.get(field) or "").upper()
        if needle in val:
            return True

    return False


def cooled_down_gaps(cooldown_dir: str, worker_id: str = "") -> set[str]:
    """FLEET-051: gap IDs cooled for this worker (or cluster-wide).

    File formats:
    - ${WORKER_ID}-${GAP_ID}.json  per-worker cooldown (FLEET-051)
    - ${GAP_ID}.json               legacy / cluster-wide cooldown

    A gap is blocked when:
      (a) it has a per-worker file for *this* worker_id whose until>now, OR
      (b) it has a cluster-wide (legacy) file whose until>now, OR
      (c) it has per-worker files from >= FLEET_COOLDOWN_THRESHOLD distinct workers

    INFRA-361: expired records are cleaned up on read.
    """
    if not cooldown_dir or not os.path.isdir(cooldown_dir):
        return set()
    threshold = int(os.environ.get("FLEET_COOLDOWN_THRESHOLD", "3"))
    now = int(time.time())
    cooled: set[str] = set()
    # gap_id → set of worker IDs still cooled
    per_worker: dict[str, set[str]] = {}

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
        if until <= now:
            # Expired — clean up the record so the directory doesn't grow.
            try:
                os.remove(path)
            except OSError:
                pass
            continue

        # Determine whether this is a per-worker or legacy/cluster-wide record.
        # Per-worker filenames start with a digit (AGENT_ID is numeric).
        stem = entry[:-5]  # strip ".json"
        is_per_worker = stem[0].isdigit() if stem else False

        if is_per_worker:
            # stem = "${AGENT_ID}-${GAP_ID}"; split on first dash only.
            dash = stem.index("-")
            file_worker = stem[:dash]
            per_worker.setdefault(gid, set()).add(file_worker)
            # Block this picker if it matches our worker_id.
            if worker_id and file_worker == str(worker_id):
                cooled.add(gid)
        else:
            # Legacy / cluster-wide file — blocks all workers.
            cooled.add(gid)

    # Cluster-wide threshold: too many distinct workers already failed.
    for gid, workers in per_worker.items():
        if len(workers) >= threshold:
            cooled.add(gid)

    return cooled


def _inbox_handoff_pick(gaps):
    """
    INFRA-1254 — inbox-first picker.

    Before scoring candidates from the registry, check this session's inbox
    (.chump-locks/inbox/<session>.jsonl) for an unread HANDOFF event. If
    found AND the named gap is still status=open in the registry, return
    that gap-id so the picker prefers explicit handoffs over the default
    score-based pick. This is how STUCK/HANDOFF events from
    pr-stuck-announcer (INFRA-1251) or stale-gap-lock-reaper (INFRA-1252)
    actually translate into worker behavior.

    Returns the gap-id string, or None to fall back to the score path.
    Operator opt-out: CHUMP_IGNORE_INBOX=1.
    """
    if os.environ.get("CHUMP_IGNORE_INBOX", "0") == "1":
        return None
    session = (
        os.environ.get("CHUMP_SESSION_ID")
        or os.environ.get("CLAUDE_SESSION_ID")
        or ""
    )
    if not session:
        return None
    lock_dir = os.environ.get("CHUMP_LOCK_DIR")
    if not lock_dir:
        repo_root = os.environ.get("CHUMP_REPO") or os.getcwd()
        lock_dir = os.path.join(repo_root, ".chump-locks")
    inbox_file = os.path.join(lock_dir, "inbox", f"{session}.jsonl")
    if not os.path.isfile(inbox_file):
        return None

    by_id = {g.get("id"): g for g in gaps if isinstance(g, dict)}
    try:
        with open(inbox_file) as fh:
            for raw in fh:
                raw = raw.strip()
                if not raw:
                    continue
                try:
                    evt = json.loads(raw)
                except Exception:
                    continue
                if evt.get("event") != "HANDOFF":
                    continue
                gid = evt.get("gap") or evt.get("corr_id") or ""
                if not gid:
                    continue
                g = by_id.get(gid)
                if not g or g.get("status") != "open":
                    continue
                return gid
    except Exception:
        return None
    return None


def _load_planner_priority(
    repo_root: str, max_age_s: int = 7200
) -> tuple[dict[str, int], str]:
    """INFRA-1258: read .chump-locks/gap-priority.json written by the
    INFRA-1257 hourly planner. Returns (gap_id -> rank, status_tag).

    The producer (chump-plan --format json via launchd) writes one entry
    per scored gap with rank ascending (1 = best). The picker uses that
    rank as the primary sort key so a betweenness-high P1 outranks a
    leaf P3 even when the legacy (prio, effort, age) score is identical.

    status_tag is one of:
      "absent"  — file missing
      "stale"   — file older than max_age_s
      "invalid" — file present but malformed JSON
      "ok"      — file present, parsed, used

    Caller may emit kind=picker_priority_stale to ambient when status_tag
    is not "ok"; picker falls back to legacy ordering in every case.
    """
    path = os.path.join(repo_root, ".chump-locks", "gap-priority.json")
    if not os.path.exists(path):
        return {}, "absent"
    try:
        mtime = os.path.getmtime(path)
    except OSError:
        return {}, "invalid"
    if (time.time() - mtime) > max_age_s:
        return {}, "stale"
    try:
        with open(path) as f:
            data = json.load(f)
    except Exception:
        return {}, "invalid"
    items = data.get("items") if isinstance(data, dict) else None
    if not isinstance(items, list):
        return {}, "invalid"
    out: dict[str, int] = {}
    for item in items:
        if not isinstance(item, dict):
            continue
        gid = item.get("gap_id")
        rank = item.get("rank")
        if isinstance(gid, str) and isinstance(rank, int):
            out[gid] = rank
    return out, "ok"


def _is_acceptance_criteria_vague(ac: str) -> bool:
    """INFRA-1259: Check if acceptance_criteria is vague (empty, all-TODO, or all-TBD).
    Returns True if the AC is empty, contains only TODO items, or contains only TBD items."""
    if not ac:
        return True

    # Try to parse as JSON array (the canonical format)
    try:
        arr = json.loads(ac)
        if isinstance(arr, list):
            if not arr:
                return True  # Empty array
            # Check if all items are TODO or TBD strings
            return all(
                isinstance(item, str) and item.upper() in ("TODO", "TBD")
                for item in arr
            )
    except (json.JSONDecodeError, TypeError):
        pass

    # If not JSON array, check if the raw string is just TODO/TBD
    upper = ac.upper()
    return upper in ("TODO", "TBD") or (len(ac) < 50 and upper.count("TODO") == 1 and len(ac.split()) <= 2)


def _emit_picker_event(repo_root: str, kind: str, **fields: object) -> None:
    """INFRA-1258: best-effort ambient emit. Never break the picker on log
    failure."""
    ambient = os.environ.get(
        "CHUMP_AMBIENT_LOG", os.path.join(repo_root, ".chump-locks", "ambient.jsonl")
    )
    ambient_dir = os.path.dirname(ambient)
    if not os.path.isdir(ambient_dir):
        return
    rec = {
        "ts": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "kind": kind,
        **{k: v for k, v in fields.items() if v is not None},
    }
    try:
        with open(ambient, "a") as f:
            f.write(json.dumps(rec) + "\n")
    except Exception:
        pass


def main() -> int:
    gap_file = os.environ.get("GAP_JSON_FILE")
    if not gap_file or not os.path.exists(gap_file):
        return 0
    try:
        with open(gap_file) as f:
            gaps = json.load(f)
    except Exception:
        return 0

    # INFRA-1254: inbox-first picker. If this session has a pending HANDOFF
    # for an open gap, claim that before falling through to score-based pick.
    handoff_gid = _inbox_handoff_pick(gaps)
    if handoff_gid:
        print(handoff_gid)
        return 0

    prio_filter = [p.upper() for p in csv("FLEET_PRIORITY_FILTER")]
    domain_filter = [d.lower() for d in csv("FLEET_DOMAIN_FILTER")]
    effort_filter = [e.lower() for e in csv("FLEET_EFFORT_FILTER")]
    worker_model = os.environ.get("FLEET_MODEL", "haiku").lower()
    exclude_re = re.compile(os.environ.get("EXCLUDE_RE", "^$"))
    active = set(os.environ.get("ACTIVE_GAPS", "").split())
    cooled = cooled_down_gaps(
        os.environ.get("COOLDOWN_DIR", ""),
        worker_id=os.environ.get("WORKER_ID", os.environ.get("AGENT_ID", "")),
    )

    # INFRA-1258: load planner priorities from .chump-locks/gap-priority.json
    # if present and fresh. The producer (chump-plan --format json, hourly via
    # launchd, INFRA-1257) writes one entry per scored gap. We use the rank as
    # the primary sort key so high-betweenness P1s outrank leaf P3s instead of
    # tying on (priority, effort, age). On absent/stale/invalid we silently
    # fall back to legacy ordering and emit kind=picker_priority_stale once.
    repo_root = os.environ.get("CHUMP_REPO", os.getcwd())
    planner_ranks, planner_status = _load_planner_priority(repo_root)
    if planner_status != "ok":
        _emit_picker_event(
            repo_root,
            "picker_priority_stale",
            reason=planner_status,
            worker_id=os.environ.get("WORKER_ID", ""),
        )

    # MISSION-011: load the active mission outcome ID. When set, mission-linked
    # gaps receive a mission_rank=0 boost that sorts them before equal-priority
    # substrate gaps (mission_rank=1). The boost is additive — it does NOT
    # override the planner_rank or prio_rank tiers; a substrate P0 still beats
    # a mission P1 (0+0 < 0+1 in the (planner_rank, mission_rank, prio_rank)
    # sort key). Disable with CHUMP_ACTIVE_MISSION="" or an empty
    # ~/.chump/ACTIVE_MISSION file.
    active_mission = _load_active_mission()

    candidates = []
    for g in gaps:
        gid = g.get("id", "")
        if not gid or gid in active:
            continue
        if gid in cooled:
            continue
        if exclude_re.search(gid):
            continue
        # INFRA-397: skip gaps that are not open. `chump gap list --json`
        # without --status open returns done/in_progress gaps too; without
        # this guard a fleet worker would happily "pick" a long-closed gap,
        # blow through preflight (already-done = bail), and waste a cycle.
        # Observed in 2026-05-02 fleet logs: 6 workers each picking the
        # same closed INFRA-340 within 90s.
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
        # INFRA-418: skip gaps that require a different model tier.
        # If gap.required_model is not set (empty string), it's compatible with any model.
        required_model = (g.get("required_model") or "").lower()
        if required_model and required_model != worker_model:
            continue
        # INFRA-471: model-class effort gate (routing.yaml drives pick policy).
        # haiku workers refuse effort=m/l/xl — cognitive overhead exceeds capability.
        # sonnet workers refuse effort=xs — cheap models handle cleanup; don't burn frontier tokens.
        # opus is unconstrained.
        if worker_model == "haiku" and e in ("m", "l", "xl"):
            continue
        if worker_model == "sonnet" and e == "xs":
            continue
        # Conservative: skip gaps with non-empty depends_on.
        # INFRA-397: depends_on arrives as a JSON-encoded string from
        # `chump gap list --json` (e.g. "[]" or '["INFRA-100"]'), not a
        # Python list. The pre-fix `if deps.strip(): continue` matched
        # "[]" too (non-empty string), so every gap with the canonical
        # empty-deps shape was silently filtered out and the picker
        # returned nothing — making it look like the queue was empty
        # while open gaps sat unpicked.
        deps_raw = g.get("depends_on")
        if isinstance(deps_raw, str):
            try:
                dep_list = json.loads(deps_raw) if deps_raw.strip() else []
            except json.JSONDecodeError:
                # Malformed depends_on — skip to be safe.
                continue
        elif isinstance(deps_raw, list):
            dep_list = deps_raw
        else:
            dep_list = []
        if dep_list:  # any non-empty dep array
            # INFRA-398: check if all dependencies are satisfied
            # (done or active) before skipping the gap.
            unresolved = [d for d in dep_list if d not in active]
            # Find which unresolved deps are actually done in the gap list
            for gap in gaps:
                if gap.get("id") in unresolved and gap.get("status") == "done":
                    unresolved.remove(gap.get("id"))
            # Skip only if there are unresolved dependencies
            if unresolved:
                continue
        # INFRA-206: skip gaps whose notes start with "SUPERSEDED" — they have
        # been superseded by another gap and should not be auto-picked.
        notes = (g.get("notes") or "").strip()
        if notes.upper().startswith("SUPERSEDED"):
            continue
        # INFRA-1259: skip gaps with empty or TODO-only acceptance_criteria
        # to avoid wasted work on unspecified requirements.
        ac_text = (g.get("acceptance_criteria") or "").strip()
        if _is_acceptance_criteria_vague(ac_text):
            continue

        # INFRA-756: downrank gaps with incomplete acceptance_criteria (obs-AC placeholders)
        # by adding 5 to priority rank. This keeps them pickable but below fully-specified gaps.
        prio_rank = PRIO_RANK.get(p, 9)
        ac_text_upper = ac_text.upper()
        if ac_text and ("TODO" in ac_text_upper or "TBD" in ac_text_upper or "<FILL IN>" in ac_text_upper):
            prio_rank += 5

        # INFRA-1258: planner rank takes precedence when available. Lower rank
        # = better (1 is rank-1 best). Gaps not in the planner output get a
        # sentinel large rank so they sort AFTER planner-ranked gaps but
        # remain pickable; legacy (prio_rank, effort, age) still resolves
        # ties within each bucket.
        planner_rank = planner_ranks.get(gid, 10_000)

        # MISSION-011: mission_rank = 0 for gaps linked to the active mission
        # outcome, 1 for everything else. Placed AFTER prio_rank so it acts as
        # a within-priority-band tiebreaker. A substrate P0 (prio_rank=0) still
        # beats a mission P1 (prio_rank=1) because prio_rank is compared first.
        # Within the same priority band (both P1), mission_rank=0 causes the
        # mission gap to sort before the substrate gap (mission_rank=1).
        # Sort tuple: (planner_rank, prio_rank, mission_rank, effort_rank, age, id)
        mission_rank = 0 if _is_mission_linked(g, active_mission) else 1

        candidates.append(
            (
                planner_rank,
                prio_rank,
                mission_rank,
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
        picked = candidates[offset]
        # Tuple layout: (planner_rank, prio_rank, mission_rank, effort_rank, created_at, gid)
        picked_planner_rank = picked[0]
        picked_mission_rank = picked[2]
        picked_gid = picked[-1]

        # INFRA-1258: emit attribution so operators can see whether the
        # planner influenced this pick (rank < 10_000) vs. legacy ordering.
        if planner_status == "ok" and picked_planner_rank < 10_000:
            _emit_picker_event(
                repo_root,
                "picker_used_priority",
                gap_id=picked_gid,
                planner_rank=picked_planner_rank,
                worker_id=os.environ.get("WORKER_ID", ""),
            )

        # MISSION-011: emit when mission boost influenced the pick. We detect
        # influence by checking whether mission_rank=0 AND there exists any
        # candidate with the same planner_rank AND same prio_rank but
        # mission_rank=1 (a substrate gap at equal priority that the mission
        # gap outranked purely because of the mission tiebreaker).
        # Tuple layout: (planner_rank[0], prio_rank[1], mission_rank[2], ...)
        if picked_mission_rank == 0 and active_mission:
            pr = picked[1]  # prio_rank of the picked gap
            displaced = any(
                c[0] == picked_planner_rank and c[1] == pr and c[2] == 1
                for c in candidates
                if c[-1] != picked_gid
            )
            if displaced:
                _emit_picker_event(
                    repo_root,
                    "picker_mission_boost",
                    gap_id=picked_gid,
                    active_mission=active_mission,
                    worker_id=os.environ.get("WORKER_ID", ""),
                )

        print(picked_gid)
    return 0


if __name__ == "__main__":
    sys.exit(main())
