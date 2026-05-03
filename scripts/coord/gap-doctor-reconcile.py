#!/usr/bin/env python3
"""gap-doctor-reconcile.py — INFRA-303

Bidirectional reconciler between state.db (canonical SQLite store) and
docs/gaps/<ID>.yaml (human-readable mirror). Fills missing state.db fields
from the YAML mirror so a subsequent `chump gap dump --per-file` produces
ZERO diff against the working tree.

## Why

State.db is the canonical store post-INFRA-059, but it's been drifting
from the YAML mirror. Many gaps have description / acceptance_criteria /
notes / source_doc / opened_date in their YAML files but NULL in state.db
(because pre-INFRA-200 raw-YAML edits bypassed the chump CLI, and some
older `chump gap reserve` calls only stored title/domain/priority/effort).

Symptom from 2026-05-02 dogfood: a fresh `chump gap dump --per-file`
produced 189 changed YAML files with 922 insertions / 3701 deletions —
the deletions were content state.db didn't know about.

## Strategy

For each YAML file:
  1. Parse all fields.
  2. Look up the gap in state.db.
  3. For each field, if state.db is empty/null AND YAML has a value,
     write YAML→DB via `chump gap set --<field>`.
  4. Never overwrite a non-empty state.db field with a YAML value
     (operator-curated state.db wins; YAML mirror is regen-only).

After: `chump gap dump --per-file && git diff docs/gaps/` produces 0 diff
(modulo gaps where state.db has a curated value the YAML doesn't reflect —
those are healed in the OTHER direction by the dump).

## Usage

  python3 scripts/coord/gap-doctor-reconcile.py --dry-run    # report only
  python3 scripts/coord/gap-doctor-reconcile.py              # apply

Fields reconciled: description, acceptance_criteria, notes, source_doc,
opened_date, closed_date, closed_pr, depends_on. (status, title, priority,
effort, domain are always populated by `chump gap reserve`.)
"""

import argparse
import glob
import json
import os
import subprocess
import sys
from pathlib import Path

REPO_ROOT = Path(
    subprocess.check_output(["git", "rev-parse", "--show-toplevel"]).decode().strip()
)
GAPS_DIR = REPO_ROOT / "docs" / "gaps"

# Fields we'll reconcile (state.db field name → CLI flag name).
RECONCILABLE_FIELDS = {
    "description": "--description",
    "notes": "--notes",
    "source_doc": "--source-doc",
    "opened_date": "--opened-date",
    "closed_date": "--closed-date",
    "closed_pr": "--closed-pr",
    # acceptance_criteria + depends_on are list-shaped; handled specially below.
}


def load_db() -> dict:
    """Returns {gap_id: row_dict} from `chump gap list --json`."""
    out = subprocess.check_output(["chump", "gap", "list", "--json"]).decode()
    return {g["id"]: g for g in json.loads(out)}


def parse_yaml_file(path: Path) -> dict:
    """Parse a docs/gaps/<ID>.yaml file. Uses PyYAML if available; falls
    back to a tiny regex parser for fields we care about. Returns a dict
    with the keys we reconcile (description/notes/etc.)."""
    text = path.read_text(encoding="utf-8")
    try:
        import yaml  # type: ignore

        data = yaml.safe_load(text)
        if isinstance(data, list):
            data = data[0] if data else {}
        return data if isinstance(data, dict) else {}
    except Exception:
        # Regex fallback (won't capture multi-line description well — best-effort).
        import re

        out = {}
        for field in [
            "description",
            "notes",
            "source_doc",
            "opened_date",
            "closed_date",
            "closed_pr",
        ]:
            m = re.search(rf"^\s*{field}:\s*['\"]?(.+?)['\"]?\s*$", text, re.M)
            if m:
                out[field] = m.group(1)
        return out


def is_empty(v) -> bool:
    """Treat None / empty-string / empty-list as empty for reconciliation."""
    return v is None or v == "" or v == [] or v == "null"


def normalize(v) -> str:
    """Normalize a value to string for comparison."""
    if isinstance(v, list):
        return "|".join(str(x) for x in v)
    return str(v) if v is not None else ""


def reconcile_one(gid: str, yaml_data: dict, db_row: dict, dry_run: bool) -> list:
    """Return a list of (field, action, value) for each reconciliation."""
    actions = []

    for field, flag in RECONCILABLE_FIELDS.items():
        yaml_v = yaml_data.get(field)
        db_v = db_row.get(field)
        if not is_empty(yaml_v) and is_empty(db_v):
            value = str(yaml_v).strip()
            actions.append((field, "set", value))
            if not dry_run:
                cmd = ["chump", "gap", "set", gid, flag, value]
                r = subprocess.run(cmd, capture_output=True, text=True)
                if r.returncode != 0:
                    print(
                        f"  WARN {gid} {field}: chump gap set failed: {r.stderr.strip()[:80]}",
                        file=sys.stderr,
                    )

    # acceptance_criteria — pipe-separated list
    yaml_ac = yaml_data.get("acceptance_criteria")
    db_ac = db_row.get("acceptance_criteria")
    # YAML list → "a|b|c"; DB stores as JSON array string sometimes.
    if isinstance(yaml_ac, list) and yaml_ac and is_empty(db_ac):
        joined = "|".join(str(x).strip() for x in yaml_ac)
        actions.append(("acceptance_criteria", "set", joined))
        if not dry_run:
            r = subprocess.run(
                ["chump", "gap", "set", gid, "--acceptance-criteria", joined],
                capture_output=True,
                text=True,
            )
            if r.returncode != 0:
                print(
                    f"  WARN {gid} acceptance_criteria: {r.stderr.strip()[:80]}",
                    file=sys.stderr,
                )

    # depends_on — comma-separated
    yaml_dep = yaml_data.get("depends_on")
    db_dep = db_row.get("depends_on")
    if isinstance(yaml_dep, list) and yaml_dep and is_empty(db_dep):
        joined = ",".join(str(x).strip() for x in yaml_dep)
        actions.append(("depends_on", "set", joined))
        if not dry_run:
            r = subprocess.run(
                ["chump", "gap", "set", gid, "--depends-on", joined],
                capture_output=True,
                text=True,
            )
            if r.returncode != 0:
                print(
                    f"  WARN {gid} depends_on: {r.stderr.strip()[:80]}",
                    file=sys.stderr,
                )

    return actions


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--dry-run", action="store_true", help="report without writing")
    ap.add_argument(
        "--limit", type=int, default=0, help="cap to first N gaps (debugging)"
    )
    args = ap.parse_args()

    if not GAPS_DIR.is_dir():
        print(f"ERROR: {GAPS_DIR} not a directory", file=sys.stderr)
        sys.exit(2)

    print(f"Loading state.db…")
    db = load_db()
    print(f"  {len(db)} rows")

    yaml_files = sorted(GAPS_DIR.glob("*.yaml"))
    if args.limit:
        yaml_files = yaml_files[: args.limit]
    print(f"Scanning {len(yaml_files)} YAML files…")

    total_actions = 0
    gaps_touched = 0
    skipped_no_db = 0
    for path in yaml_files:
        gid = path.stem
        if gid not in db:
            skipped_no_db += 1
            continue
        yaml_data = parse_yaml_file(path)
        actions = reconcile_one(gid, yaml_data, db[gid], args.dry_run)
        if actions:
            gaps_touched += 1
            total_actions += len(actions)
            if args.dry_run:
                fields = ", ".join(a[0] for a in actions)
                print(f"  {gid}: would set {fields}")

    print()
    print(f"Summary:")
    print(f"  YAML files scanned   : {len(yaml_files)}")
    print(f"  Skipped (no DB row)  : {skipped_no_db}")
    print(f"  Gaps touched         : {gaps_touched}")
    print(f"  Total field updates  : {total_actions}")
    if args.dry_run:
        print(f"  (dry-run — no writes)")
    else:
        print(f"  (writes applied; verify via gap-doctor + chump gap dump --per-file)")


if __name__ == "__main__":
    main()
