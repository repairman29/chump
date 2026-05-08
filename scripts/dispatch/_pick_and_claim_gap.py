#!/usr/bin/env python3
"""INFRA-415 + FLEET-046: atomic gap picker+claimer for fleet workers.

Extends _pick_gap.py with claiming logic so gap-picker returns ONLY gaps
that have already been claimed (atomically) by this invocation. Prevents
concurrent workers from picking the same gap.

FLEET-046: pillar-aware rebalancing. Reads recent ship history from
state.db to detect domain monopoly (e.g. INFRA >70% of last 20 ships)
and pillar starvation (a pillar absent from recent ships). Gaps from
underserved domains/pillars get a sort-key boost so they surface ahead
of yet-another-INFRA-fix.

Reads the open-gap JSON, applies fleet filters, attempts to claim each
candidate in priority order. Returns the first gap that was successfully
claimed, or nothing if all candidates are already claimed/unavailable.

Environment (same as _pick_gap.py plus):
  SESSION_ID       session identifier for lease (e.g. from CLAUDE_SESSION_ID)
  CHUMP_LOCK_DIR   override .chump-locks path (default: repo_root/.chump-locks)
  FLEET_MODEL      worker's model tier (haiku, sonnet, opus) for filtering by required_model
  CHUMP_REBALANCE  set to "0" to disable pillar/domain rebalancing (default: enabled)
  CHUMP_STATE_DB   override path to state.db (default: repo_root/.chump/state.db)
  REBALANCE_WINDOW number of recent ships to consider (default: 20)
  REBALANCE_DOMAIN_THRESHOLD  domain monopoly threshold 0-100 (default: 70)
"""

from __future__ import annotations

import fcntl
import json
import os
import re
import subprocess
import sys
import time
from pathlib import Path

PRIO_RANK = {"P0": 0, "P1": 1, "P2": 2, "P3": 3, "": 9}
EFFORT_RANK = {"xs": 0, "s": 1, "m": 2, "l": 3, "xl": 4, "": 9}
PILLAR_TAGS = {"EFFECTIVE", "CREDIBLE", "RESILIENT", "ZERO-WASTE", "MISSION"}


def extract_pillar(title: str) -> str:
    """Extract pillar tag from gap title (e.g. 'EFFECTIVE: foo bar' → 'EFFECTIVE')."""
    upper = title.lstrip().upper()
    for tag in PILLAR_TAGS:
        if upper.startswith(tag + ":"):
            return tag
    return ""


def get_ship_history(window: int) -> list[dict]:
    """Read last `window` shipped gaps from state.db. Returns [{domain, title}]."""
    repo_root = os.environ.get("REPO_ROOT", ".")
    db_path = os.environ.get("CHUMP_STATE_DB", os.path.join(repo_root, ".chump", "state.db"))
    if not os.path.exists(db_path):
        return []
    try:
        import sqlite3
        conn = sqlite3.connect(db_path)
        rows = conn.execute(
            "SELECT domain, title FROM gaps "
            "WHERE status='done' AND closed_pr IS NOT NULL "
            "ORDER BY closed_at DESC LIMIT ?",
            (window,),
        ).fetchall()
        conn.close()
        return [{"domain": r[0], "title": r[1]} for r in rows]
    except Exception:
        return []


def compute_rebalance_boosts(
    ship_history: list[dict],
    domain_threshold: int,
) -> tuple[str, set[str]]:
    """Return (monopoly_domain, starved_pillars) based on ship history imbalance.

    monopoly_domain: the domain that exceeds threshold% of recent ships (e.g.
    "INFRA" at 100%). Empty string if no monopoly. Caller boosts any gap whose
    domain != monopoly_domain.

    starved_pillars: pillar tags absent from recent ship titles. If no recent
    ship has an EFFECTIVE: prefix, EFFECTIVE-tagged gaps get a boost.
    """
    if not ship_history:
        return "", set()

    domain_counts: dict[str, int] = {}
    seen_pillars: set[str] = set()
    for s in ship_history:
        d = (s.get("domain") or "").upper()
        if d:
            domain_counts[d] = domain_counts.get(d, 0) + 1
        pillar = extract_pillar(s.get("title", ""))
        if pillar:
            seen_pillars.add(pillar)

    total = len(ship_history)
    monopoly_domain: str = ""
    for domain, count in domain_counts.items():
        pct = (count * 100) // total
        if pct >= domain_threshold:
            monopoly_domain = domain.upper()
            break

    starved_pillars = PILLAR_TAGS - seen_pillars

    return monopoly_domain, starved_pillars


def csv(env_key: str) -> list[str]:
    return [s.strip() for s in os.environ.get(env_key, "").split(",") if s.strip()]


def get_session_id() -> str:
    """Resolve session ID in priority order (same as gap-claim.sh)."""
    # Priority 1: explicit override
    if os.environ.get("CHUMP_SESSION_ID"):
        return os.environ["CHUMP_SESSION_ID"]

    # Priority 2: Claude Code SDK injection
    if os.environ.get("CLAUDE_SESSION_ID"):
        return os.environ["CLAUDE_SESSION_ID"]

    # Priority 3: worktree-scoped ID (read from .chump-locks/.wt-session-id if present)
    wt_session_path = Path(".chump-locks/.wt-session-id")
    if wt_session_path.exists():
        try:
            with open(wt_session_path) as f:
                return f.read().strip()
        except Exception:
            pass

    # Priority 4: machine-scoped fallback (read from ~/.chump/session_id)
    home = os.environ.get("HOME", os.path.expanduser("~"))
    fallback_path = Path(home) / ".chump" / "session_id"
    if fallback_path.exists():
        try:
            with open(fallback_path) as f:
                return f.read().strip()
        except Exception:
            pass

    raise ValueError("No session ID found; set CHUMP_SESSION_ID or CLAUDE_SESSION_ID")


def get_lock_dir() -> Path:
    """Get the lease lock directory.

    INFRA-467: resolve to the *main* repo's .chump-locks/, never the
    linked worktree's. Without this, a fleet spawned from
    /tmp/chump-fleet-host (a `git worktree add` of the main repo) writes
    leases into /tmp/chump-fleet-host/.chump-locks/ — invisible to siblings
    on the main repo, so cross-worktree gap-preflight breaks (INFRA-466).

    Resolution order (matches scripts/lib/repo-paths.sh):
      1. CHUMP_LOCK_DIR env override (tests, explicit)
      2. parent of `git rev-parse --git-common-dir` (main-repo root, even
         from a linked worktree — git-common-dir returns the MAIN repo's
         .git regardless of which worktree we're in)
      3. REPO_ROOT env (worker.sh sets this) / .chump-locks (legacy fallback)
      4. cwd / .chump-locks (last resort)
    """
    lock_dir = os.environ.get("CHUMP_LOCK_DIR")
    if lock_dir:
        return Path(lock_dir)

    # Try git-common-dir for main-repo resolution.
    try:
        common = subprocess.run(
            ["git", "rev-parse", "--git-common-dir"],
            capture_output=True, text=True, timeout=5,
        )
        if common.returncode == 0:
            common_dir = common.stdout.strip()
            # Linked worktree: returns absolute /path/to/main/.git
            # Main checkout: returns relative ".git"
            if common_dir == ".git":
                # Main checkout — toplevel is the main repo
                top = subprocess.run(
                    ["git", "rev-parse", "--show-toplevel"],
                    capture_output=True, text=True, timeout=5,
                )
                if top.returncode == 0:
                    return Path(top.stdout.strip()) / ".chump-locks"
            else:
                # Linked worktree — common_dir's parent is main repo root
                return Path(common_dir).resolve().parent / ".chump-locks"
    except Exception:
        pass

    # Legacy fallback: REPO_ROOT (set by worker.sh, may be the linked-worktree
    # path — preserves backward-compat for tests that explicitly set it).
    repo_root = os.environ.get("REPO_ROOT", ".")
    return Path(repo_root) / ".chump-locks"


def try_claim_gap(gap_id: str, session_id: str, lock_dir: Path) -> bool:
    """Attempt to write a lease for gap_id atomically. Return True if successful.

    Uses a two-file strategy with fcntl.flock for atomicity:
    1. gap-id.lock — canonical indicator that gap is claimed
    2. session-id.json — metadata about the claiming session

    INFRA-513: Use fcntl.flock around the check+claim pair to prevent TOCTOU race
    where two workers both scan empty leases and try to claim the same gap.
    """
    lock_dir.mkdir(parents=True, exist_ok=True)

    now = int(time.time())
    ttl_seconds = 4 * 3600
    expires_at = now + ttl_seconds

    lease = {
        "session_id": session_id,
        "gap_id": gap_id,
        "taken_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(now)),
        "expires_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(expires_at)),
        "heartbeat_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(now)),
        "purpose": "fleet:pick_and_claim",
        "speculative": True,
    }

    gap_lock_file = lock_dir / f".gap-{gap_id}.lock"
    session_lease_file = lock_dir / f"{session_id}.json"
    temp_lease = lock_dir / f".tmp-{session_id}-{gap_id}-{now}"
    lockfile = lock_dir / ".claim-lock"

    try:
        # Use fcntl.flock around the check+claim to prevent TOCTOU race.
        # This serializes access so only one worker can claim at a time.
        with open(lockfile, "a") as lock_f:
            fcntl.flock(lock_f.fileno(), fcntl.LOCK_EX)
            try:
                # Check if gap is already claimed (within the lock).
                if gap_lock_file.exists():
                    return False

                # Create the gap lock file (still within the lock).
                with open(gap_lock_file, "w") as f:
                    f.write(f"{session_id} {now}\n")

                # Gap lock created successfully. Now write the session lease.
                try:
                    with open(temp_lease, "w") as f:
                        json.dump(lease, f, indent=2)
                    temp_lease.rename(session_lease_file)
                except Exception:
                    # Lease write failed, but we already created the lock.
                    # Return True anyway since we successfully claimed the gap.
                    pass

                return True
            finally:
                fcntl.flock(lock_f.fileno(), fcntl.LOCK_UN)

    except Exception:
        return False


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

    session_id = get_session_id()
    lock_dir = get_lock_dir()

    prio_filter = [p.upper() for p in csv("FLEET_PRIORITY_FILTER")]
    domain_filter = [d.lower() for d in csv("FLEET_DOMAIN_FILTER")]
    effort_filter = [e.lower() for e in csv("FLEET_EFFORT_FILTER")]
    worker_model = os.environ.get("FLEET_MODEL", "haiku").lower()
    exclude_re = re.compile(os.environ.get("EXCLUDE_RE", "^$"))
    active = set(os.environ.get("ACTIVE_GAPS", "").split())
    cooled = cooled_down_gaps(os.environ.get("COOLDOWN_DIR", ""))

    # INFRA-314: Worker skill affinity scoring.
    # CHUMP_AFFINITY=0 disables affinity matching (treats all gaps as eligible).
    affinity_enabled = os.environ.get("CHUMP_AFFINITY", "1") != "0"
    worker_skills = set(
        s.lower().strip()
        for s in os.environ.get("WORKER_SKILLS", "").split(",")
        if s.strip()
    ) if affinity_enabled else set()

    # FLEET-046: pillar/domain rebalancing.
    rebalance_enabled = os.environ.get("CHUMP_REBALANCE", "1") != "0"
    monopoly_domain: str = ""
    starved_pillars: set[str] = set()
    if rebalance_enabled:
        window = int(os.environ.get("REBALANCE_WINDOW", "20"))
        threshold = int(os.environ.get("REBALANCE_DOMAIN_THRESHOLD", "70"))
        ship_history = get_ship_history(window)
        monopoly_domain, starved_pillars = compute_rebalance_boosts(
            ship_history, threshold
        )

    candidates = []
    for g in gaps:
        gid = g.get("id", "")
        if not gid or gid in active:
            continue
        if gid in cooled:
            continue
        if exclude_re.search(gid):
            continue
        if g.get("status") != "open":
            continue
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
        deps_raw = g.get("depends_on")
        if isinstance(deps_raw, str):
            try:
                dep_list = json.loads(deps_raw) if deps_raw.strip() else []
            except json.JSONDecodeError:
                continue
        elif isinstance(deps_raw, list):
            dep_list = deps_raw
        else:
            dep_list = []
        if dep_list:
            continue

        # INFRA-314: Extract affinity metadata (only when affinity is enabled).
        affinity_score = 0
        if affinity_enabled:
            skills_required_raw = g.get("skills_required", "")
            if isinstance(skills_required_raw, str):
                try:
                    skills_required = (
                        json.loads(skills_required_raw)
                        if skills_required_raw.strip()
                        else []
                    )
                except json.JSONDecodeError:
                    skills_required = []
            elif isinstance(skills_required_raw, list):
                skills_required = skills_required_raw
            else:
                skills_required = []

            # Normalize to lowercase for comparison.
            skills_required = {s.lower() for s in skills_required}

            preferred_backend = (g.get("preferred_backend") or "").lower()
            preferred_machine = (g.get("preferred_machine") or "").lower()

            # Hard filter: if gap requires skills, worker must have all of them.
            if skills_required and not skills_required.issubset(worker_skills):
                continue

            # Affinity scoring: backend match (3) + machine match (2) + skill matches (1 each) + priority.
            worker_backend = os.environ.get("WORKER_BACKEND", "").lower()
            if worker_backend and preferred_backend and worker_backend == preferred_backend:
                affinity_score += 3
            worker_machine = os.environ.get("WORKER_MACHINE", "").lower()
            if worker_machine and preferred_machine and worker_machine == preferred_machine:
                affinity_score += 2
            # Each matched skill adds 1 point (up to len(skills_required)).
            affinity_score += len(skills_required & worker_skills)

        # FLEET-046: rebalance boost. Gaps from underserved domains/pillars
        # get a sort-key bonus equivalent to bumping them up 2 priority
        # levels (e.g. P2 sorts like P0).
        rebalance_boost = 0
        if rebalance_enabled:
            title = g.get("title", "")
            gap_domain = d.upper()
            gap_pillar = extract_pillar(title)
            if monopoly_domain and gap_domain != monopoly_domain:
                rebalance_boost += 2
            if gap_pillar and gap_pillar in starved_pillars:
                rebalance_boost += 2

        effective_prio = max(PRIO_RANK.get(p, 9) - rebalance_boost, 0)

        # Primary sort: affinity (desc), effective priority, effort, created_at.
        candidates.append(
            (
                -affinity_score,
                effective_prio,
                EFFORT_RANK.get(e, 9),
                g.get("created_at") or 0,
                gid,
            )
        )

    candidates.sort()

    if candidates:
        # Try to claim candidates in priority order. Return the first one we
        # successfully claim. This ensures no two workers return the same gap.
        try:
            worker_idx = int(os.environ.get("WORKER_INDEX", "1"))
        except ValueError:
            worker_idx = 1

        # Start from staggered offset (same logic as _pick_gap.py).
        offset = (max(worker_idx, 1) - 1) % len(candidates)

        # INFRA-569: dry-run mode — pick without claiming (no lease written).
        dry_run = os.environ.get("CHUMP_FLEET_DRY_RUN", "0") == "1"

        # Try candidates in rotated order.
        for i in range(len(candidates)):
            idx = (offset + i) % len(candidates)
            gap_id = candidates[idx][4]  # Index changed from [3] to [4] due to affinity_score.
            if dry_run:
                print(gap_id)
                return 0
            if try_claim_gap(gap_id, session_id, lock_dir):
                # FLEET-046: log when rebalancing influenced the pick.
                if rebalance_enabled and (monopoly_domain or starved_pillars):
                    ambient_path = os.environ.get(
                        "AMBIENT_JSONL", ".chump-locks/ambient.jsonl"
                    )
                    try:
                        event = {
                            "ts": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
                            "event": "INFO",
                            "kind": "rebalance_active",
                            "picked": gap_id,
                            "monopoly_domain": monopoly_domain,
                            "starved_pillars": sorted(starved_pillars),
                        }
                        with open(ambient_path, "a") as f:
                            f.write(json.dumps(event) + "\n")
                    except Exception:
                        pass
                print(gap_id)
                return 0
    else:
        # INFRA-314: Emit affinity_starved if no eligible gaps found and affinity is enabled + worker has skill constraints.
        if affinity_enabled and worker_skills:
            import time

            now = int(time.time())
            ambient_event = {
                "event": "ALERT",
                "kind": "affinity_starved",
                "worker_skills": list(worker_skills),
                "timestamp": time.strftime(
                    "%Y-%m-%dT%H:%M:%SZ", time.gmtime(now)
                ),
            }
            ambient_path = os.environ.get("AMBIENT_JSONL", ".chump-locks/ambient.jsonl")
            try:
                with open(ambient_path, "a") as f:
                    f.write(json.dumps(ambient_event) + "\n")
            except Exception:
                pass

    return 0


if __name__ == "__main__":
    sys.exit(main())
