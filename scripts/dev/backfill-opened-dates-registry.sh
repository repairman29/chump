#!/usr/bin/env bash
# backfill-opened-dates-registry.sh — INFRA-1611
#
# Backfills opened_date directly on the TRACKED canonical registry source —
# .chump/state.sql (the YAML dump restored into state.db via
# `chump gap restore --from-sql`, INFRA-538) — for open gaps missing it.
#
# Deliberately does NOT touch docs/gaps/<ID>.yaml: those per-file mirrors are
# no longer regenerated on gap mutation (ZERO-WASTE-020) and can be stale
# relative to state.sql (e.g. a gap shown "status: done" in its stale
# per-file mirror while state.sql — the real source of truth — has it
# "status: open"). Patching the stale mirror would just add noise.
#
# This complements scripts/dev/backfill-opened-dates.sh (EVAL-086), which
# patches a *live* .chump/state.db directly via sqlite3. That script is a
# no-op on a fresh checkout/CI runner where state.db hasn't been restored
# from state.sql yet; this script fixes the tracked source itself so the
# fix survives a restore.
#
# Strategy per gap missing opened_date:
#   1. git log --diff-filter=A on docs/gaps/<ID>.yaml -> date the gap file
#      first appeared (authoritative "opened" signal).
#   2. Fall back to today (UTC) if no such commit is found (e.g. the gap
#      only ever lived in state.sql, never had a per-file mirror).
#
# Usage:
#   scripts/dev/backfill-opened-dates-registry.sh [--dry-run] [--all]
#
# Default scope: open P0/P1 gaps only (the aging census that actually
# gates the P0 budget enforcement). Pass --all to backfill every open gap
# missing opened_date, regardless of priority.

set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$REPO_ROOT"

DRY_RUN=0
ALL=0
for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY_RUN=1 ;;
        --all) ALL=1 ;;
        *) echo "unknown arg: $arg" >&2; exit 2 ;;
    esac
done

SQL_PATH="$REPO_ROOT/.chump/state.sql"
if [[ ! -f "$SQL_PATH" ]]; then
    echo "ERROR: $SQL_PATH not found" >&2
    exit 1
fi

python3 - "$SQL_PATH" "$DRY_RUN" "$ALL" <<'PYEOF'
import sys
import subprocess
import re
from datetime import datetime, timezone

sql_path, dry_run, all_gaps = sys.argv[1], sys.argv[2] == "1", sys.argv[3] == "1"

import yaml
with open(sql_path) as f:
    raw = f.read()
data = yaml.safe_load(raw)
gaps = data["gaps"]

targets = [
    g for g in gaps
    if g.get("status") == "open"
    and not (g.get("opened_date") or "").strip()
    and (all_gaps or g.get("priority") in ("P0", "P1"))
]

updated = 0
skipped = 0
for g in targets:
    gid = g["id"]
    yaml_path = f"docs/gaps/{gid}.yaml"
    date_str = ""
    try:
        out = subprocess.run(
            ["git", "log", "--diff-filter=A", "--pretty=format:%ad", "--date=short", "--", yaml_path],
            capture_output=True, text=True, cwd=".",
        ).stdout.strip()
        if out:
            date_str = out.splitlines()[-1]
    except Exception:
        pass
    source = "yaml_commit"
    if not date_str:
        date_str = datetime.now(timezone.utc).strftime("%Y-%m-%d")
        source = "today_fallback"

    prefix = "[DRY-RUN] " if dry_run else ""
    print(f"  {prefix}UPDATE {gid} opened_date={date_str} (source={source})")

    if not dry_run:
        # 1. Patch state.sql in place (targeted regex on this gap's block —
        #    avoids a full yaml.dump() re-serialization that would reformat
        #    every other one of the ~4000 gaps in the file).
        block_re = re.compile(
            rf"(- id: {re.escape(gid)}\n(?:  .*\n|    .*\n)*)", re.MULTILINE
        )
        m = block_re.search(raw)
        if m and "opened_date:" not in m.group(1):
            new_block = m.group(1) + f"  opened_date: '{date_str}'\n"
            raw = raw[: m.start()] + new_block + raw[m.end() :]

    updated += 1

if not dry_run:
    with open(sql_path, "w") as f:
        f.write(raw)

print(f"\nBackfill complete: updated={updated} skipped={skipped} dry_run={dry_run} scope={'all-open' if all_gaps else 'P0/P1-open'}")
PYEOF
