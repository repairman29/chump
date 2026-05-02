#!/usr/bin/env python3
# INFRA-155: gap-store drift detector + repair tool.
#
# State.db (canonical since INFRA-059) and docs/gaps.yaml (human-readable
# mirror) routinely disagree because pre-INFRA-152 close PRs hand-edited
# YAML without updating state.db. Cold Water reads state.db via
# `chump gap list --status open`, so YAML closures invisible to the DB show
# up as OPEN-BUT-LANDED in the audit. Issue #8 named this as 65/88 (74%) of
# all open gaps; this tool drains the existing backlog and reports residual
# drift so the next sweep is targeted.
#
# Modes (all read-only by default; pass --apply to mutate):
#
#   doctor          Print a 4-bucket drift report:
#                     1. DB done / YAML open  — DB ahead of YAML, regen needed
#                     2. DB open / YAML done  — pre-INFRA-152 hand-edit; DB
#                                                missed the closure
#                     3. DB-only IDs          — gaps in state.db with no YAML
#                                                row (orphans)
#                     4. YAML-only IDs        — gaps in YAML with no DB row
#                                                (skipped on import)
#
#   sync-from-yaml  For bucket 2 (DB open / YAML done): UPDATE state.db
#                   rows to match YAML's status='done', pulling closed_at,
#                   closed_date, closed_pr from the YAML entry. Idempotent.
#
#   sync-from-db    For bucket 1 (DB done / YAML open): rewrite YAML rows
#                   from the DB. Implemented by calling
#                   `chump gap dump --out docs/gaps.yaml` (preserves the
#                   meta: preamble per INFRA-147).
#
# Read-only by default. Use --apply to actually mutate.
#
# Usage:
#   scripts/coord/gap-doctor.py doctor
#   scripts/coord/gap-doctor.py sync-from-yaml [--apply]
#   scripts/coord/gap-doctor.py sync-from-db [--apply]

import argparse
import datetime as dt
import os
import re
import sqlite3
import subprocess
import sys
from pathlib import Path

try:
    import yaml
except ImportError:
    print("error: PyYAML not installed (pip install pyyaml)", file=sys.stderr)
    sys.exit(2)


def repo_root() -> Path:
    """Return the directory whose `.chump/state.db` is canonical.

    Linked worktrees each have their own `.chump/` directory but the chump
    binary writes to the *main* worktree's state.db (its `repo_root` is
    baked at install time). Walk `git worktree list --porcelain` to find
    the first listed worktree (= the main one) and use that. If that
    state.db doesn't exist, fall back to the current worktree's root.
    """
    porcelain = subprocess.check_output(
        ["git", "worktree", "list", "--porcelain"], text=True
    )
    main_path = None
    for line in porcelain.splitlines():
        if line.startswith("worktree "):
            main_path = Path(line[len("worktree "):])
            break
    if main_path and (main_path / ".chump" / "state.db").exists():
        size = (main_path / ".chump" / "state.db").stat().st_size
        if size > 0:
            return main_path
    out = subprocess.check_output(["git", "rev-parse", "--show-toplevel"], text=True)
    return Path(out.strip())


def load_yaml_status(root: Path) -> dict:
    """Returns {gap_id: yaml_dict_for_that_gap}. Reads working-tree YAML.

    INFRA-245: post-INFRA-188 the canonical mirror is the per-file directory
    docs/gaps/<ID>.yaml, not the monolithic docs/gaps.yaml (which was
    retired in PR #753). Prefer the per-file directory when present; fall
    back to the monolithic file only for backward-compat.
    """
    out = {}
    per_file_dir = root / "docs" / "gaps"
    monolithic = root / "docs" / "gaps.yaml"

    if per_file_dir.is_dir():
        # Each docs/gaps/<ID>.yaml is the chump-gap-dump-per-file shape:
        # a one-element list whose first entry is the gap dict.
        for path in sorted(per_file_dir.glob("*.yaml")):
            try:
                data = yaml.safe_load(path.read_text(encoding="utf-8"))
            except Exception:
                continue
            entries = data if isinstance(data, list) else [data]
            for g in entries:
                if not isinstance(g, dict):
                    continue
                gid = g.get("id")
                if gid:
                    out[gid] = g
        return out

    # Legacy monolithic path (pre-INFRA-188 fallback).
    text = monolithic.read_text(encoding="utf-8")
    data = yaml.safe_load(text)
    for g in data.get("gaps", []):
        gid = g.get("id")
        if not gid:
            continue
        out[gid] = g
    return out


def load_db_status(root: Path) -> dict:
    """Returns {gap_id: row_dict}."""
    db = root / ".chump" / "state.db"
    conn = sqlite3.connect(str(db))
    conn.row_factory = sqlite3.Row
    cur = conn.execute(
        "SELECT id, status, closed_at, closed_date, closed_pr FROM gaps"
    )
    out = {row["id"]: dict(row) for row in cur}
    conn.close()
    return out


def cmd_doctor(args, root: Path) -> int:
    yaml_view = load_yaml_status(root)
    db_view = load_db_status(root)

    db_done_yaml_open = []
    db_open_yaml_done = []
    db_only = []
    yaml_only = []

    all_ids = set(yaml_view) | set(db_view)
    for gid in sorted(all_ids):
        y = yaml_view.get(gid)
        d = db_view.get(gid)
        if d is None:
            yaml_only.append(gid)
            continue
        if y is None:
            db_only.append(gid)
            continue
        if d["status"] == "done" and y.get("status") != "done":
            db_done_yaml_open.append(gid)
        elif d["status"] == "open" and y.get("status") == "done":
            db_open_yaml_done.append(gid)

    print("== gap-doctor: drift report ==")
    print(f"  Total gaps in YAML : {len(yaml_view)}")
    print(f"  Total gaps in DB   : {len(db_view)}")
    print()
    print(
        f"  Bucket 1 — DB done / YAML open   : {len(db_done_yaml_open):3} "
        "(regenerate YAML)"
    )
    for gid in db_done_yaml_open:
        print(f"      {gid}")
    print(
        f"  Bucket 2 — DB open / YAML done   : {len(db_open_yaml_done):3} "
        "(sync DB from YAML)"
    )
    for gid in db_open_yaml_done:
        print(f"      {gid}")
    print(
        f"  Bucket 3 — DB-only / YAML missing: {len(db_only):3} "
        "(orphan rows in DB)"
    )
    for gid in db_only:
        print(f"      {gid}")
    print(
        f"  Bucket 4 — YAML-only / DB missing: {len(yaml_only):3} "
        "(import skipped)"
    )
    for gid in yaml_only[:20]:
        print(f"      {gid}")
    if len(yaml_only) > 20:
        print(f"      ... {len(yaml_only) - 20} more")

    drift_total = (
        len(db_done_yaml_open) + len(db_open_yaml_done)
        + len(db_only) + len(yaml_only)
    )
    print()
    print(f"  Total drift entries: {drift_total}")
    return 0 if drift_total == 0 else 1


def parse_iso_to_unix(s: str) -> int:
    """ISO YYYY-MM-DD -> unix epoch (UTC midnight). Returns 0 on parse fail."""
    if not s:
        return 0
    try:
        dtobj = dt.datetime.strptime(s.strip().strip("'").strip('"'), "%Y-%m-%d")
        dtobj = dtobj.replace(tzinfo=dt.timezone.utc)
        return int(dtobj.timestamp())
    except ValueError:
        return 0


def coerce_int(v) -> int | None:
    if v is None:
        return None
    if isinstance(v, int):
        return v if v > 0 else None
    if isinstance(v, str):
        s = v.strip().strip("'").strip('"')
        try:
            n = int(s)
            return n if n > 0 else None
        except ValueError:
            return None
    return None


def cmd_sync_from_yaml(args, root: Path) -> int:
    yaml_view = load_yaml_status(root)
    db_view = load_db_status(root)

    db = root / ".chump" / "state.db"
    conn = sqlite3.connect(str(db))
    cur = conn.cursor()

    plan = []
    for gid, y in yaml_view.items():
        if y.get("status") != "done":
            continue
        d = db_view.get(gid)
        if d is None:
            # Bucket 4 — DB doesn't even have the row. Skipped here; that's
            # an import problem, not a status sync problem.
            continue
        if d["status"] == "done":
            continue
        # YAML done, DB open. Build the UPDATE.
        cd_raw = y.get("closed_date")
        if isinstance(cd_raw, dt.date):
            closed_date = cd_raw.isoformat()
        elif isinstance(cd_raw, str):
            closed_date = cd_raw.strip().strip("'").strip('"')
        else:
            closed_date = ""
        closed_pr = coerce_int(y.get("closed_pr"))
        closed_at = parse_iso_to_unix(closed_date)
        plan.append((gid, closed_date, closed_pr, closed_at))

    print(f"== sync-from-yaml: {len(plan)} rows to update ==")
    for gid, cd, cp, ca in plan:
        print(f"  {gid:14}  status open->done  closed_date={cd!r:14}  closed_pr={cp}")

    if not args.apply:
        print()
        print("(dry-run — pass --apply to mutate state.db)")
        return 0

    if not plan:
        print("nothing to do")
        return 0

    for gid, cd, cp, ca in plan:
        cur.execute(
            "UPDATE gaps SET status='done', closed_at=?, closed_date=?, closed_pr=? "
            "WHERE id=? AND status='open'",
            (ca if ca > 0 else None, cd, cp, gid),
        )
    conn.commit()
    conn.close()
    print(f"applied: {len(plan)} rows")

    # Regenerate the human-readable SQL dump so the diff is reviewable.
    subprocess.run(
        ["chump", "gap", "dump", "--out", str(root / ".chump" / "state.sql")],
        check=False, capture_output=True,
    )
    return 0


def cmd_sync_from_db(args, root: Path) -> int:
    """Regenerate docs/gaps.yaml from state.db, preserving the meta: preamble.
    Closes Bucket 1 (DB done / YAML open) by overwriting YAML rows with DB
    truth. Uses `chump gap dump --out` which calls dump_yaml_with_meta when
    the destination already exists (INFRA-147)."""
    yaml_path = root / "docs" / "gaps.yaml"
    if not args.apply:
        # Show what would change.
        result = subprocess.run(
            ["chump", "gap", "dump", "--out", "/dev/null"],
            capture_output=True, text=True,
        )
        # Can't easily diff /dev/null; just emit the plan.
        yaml_view = load_yaml_status(root)
        db_view = load_db_status(root)
        plan = [
            gid for gid, d in db_view.items()
            if d["status"] == "done"
            and yaml_view.get(gid, {}).get("status") != "done"
        ]
        print(f"== sync-from-db: {len(plan)} rows would flip in YAML ==")
        for gid in plan:
            print(f"  {gid}")
        print()
        print("(dry-run — pass --apply to regenerate docs/gaps.yaml)")
        return 0

    r = subprocess.run(
        ["chump", "gap", "dump", "--out", str(yaml_path)],
        capture_output=True, text=True,
    )
    if r.returncode != 0:
        print(f"chump gap dump failed: {r.stderr}", file=sys.stderr)
        return 1
    print(f"regenerated {yaml_path}")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(description="gap-store drift detector + repair (INFRA-155)")
    sub = ap.add_subparsers(dest="cmd", required=True)

    sub.add_parser("doctor", help="print drift report (read-only)")

    p1 = sub.add_parser("sync-from-yaml", help="UPDATE DB rows where YAML says done")
    p1.add_argument("--apply", action="store_true", help="actually mutate state.db")

    p2 = sub.add_parser("sync-from-db", help="regenerate YAML from DB (preserves meta:)")
    p2.add_argument("--apply", action="store_true", help="actually rewrite docs/gaps.yaml")

    args = ap.parse_args()
    root = repo_root()
    handlers = {
        "doctor": cmd_doctor,
        "sync-from-yaml": cmd_sync_from_yaml,
        "sync-from-db": cmd_sync_from_db,
    }
    return handlers[args.cmd](args, root)


if __name__ == "__main__":
    sys.exit(main())
