#!/usr/bin/env bash
# scripts/dev/audit-stale-closed-pr-refs.sh — INFRA-1911
#
# Scans open gaps in .chump/state.db whose description or notes reference #NNN
# where .chump/github_cache.db pr_state shows state='CLOSED' and merged_at IS NULL/empty.
# Emits kind=stale_closed_pr_ref per hit; with --apply, appends a warning note to
# the gap's notes column. Exits 0 when clean, 1 when stale refs are found.
#
# scanner-anchor: "kind":"stale_closed_pr_ref"
set -euo pipefail

REPO_ROOT="${REPO_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
STATE_DB="${CHUMP_STATE_DB:-$REPO_ROOT/.chump/state.db}"
CACHE_DB="${CHUMP_GITHUB_CACHE_DB:-$REPO_ROOT/.chump/github_cache.db}"
AMBIENT_FILE="${AMBIENT_JSONL:-$REPO_ROOT/.chump-locks/ambient.jsonl}"

APPLY=0
for arg in "$@"; do
    case "$arg" in
        --apply) APPLY=1 ;;
    esac
done

if [[ ! -f "$STATE_DB" || ! -f "$CACHE_DB" ]]; then
    exit 0
fi

python3 - "$STATE_DB" "$CACHE_DB" "$AMBIENT_FILE" "$APPLY" <<'PY'
import datetime
import json
import os
import re
import sqlite3
import sys

state_db, cache_db, ambient_file, apply_flag = (
    sys.argv[1],
    sys.argv[2],
    sys.argv[3],
    sys.argv[4] == "1",
)

scon = sqlite3.connect(state_db)
ccon = sqlite3.connect(cache_db)

closed_unmerged: set[int] = set()
try:
    cur = ccon.execute(
        "SELECT number, merged_at, raw_payload_json FROM pr_state"
    )
    for num, merged_at, raw_json in cur:
        if merged_at:
            continue
        state = ""
        if raw_json:
            try:
                payload = json.loads(raw_json)
                state = (
                    payload.get("state")
                    or (payload.get("pull_request") or {}).get("state")
                    or ""
                ).upper()
            except Exception:
                state = ""
        if state == "CLOSED":
            closed_unmerged.add(int(num))
except sqlite3.OperationalError:
    try:
        for (num,) in ccon.execute(
            "SELECT number FROM pr_state WHERE UPPER(state)='CLOSED' AND (merged_at IS NULL OR merged_at='')"
        ):
            closed_unmerged.add(int(num))
    except Exception:
        sys.exit(0)

if not closed_unmerged:
    sys.exit(0)

hits = 0
ts = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
os.makedirs(os.path.dirname(ambient_file) or ".", exist_ok=True)

rows = scon.execute(
    "SELECT id, COALESCE(description, ''), COALESCE(notes, '') FROM gaps WHERE LOWER(status) = 'open'"
).fetchall()

for gid, desc, notes in rows:
    text = f"{desc} {notes}"
    refs = sorted({int(m.group(1)) for m in re.finditer(r"#(\d+)", text)})
    stale = [n for n in refs if n in closed_unmerged]
    for pr_num in stale:
        hits += 1
        print(f"STALE_CLOSED_PR_REF: {gid} references closed-unmerged PR #{pr_num}")
        event = {
            "ts": ts,
            "kind": "stale_closed_pr_ref",
            "event": "stale_closed_pr_ref",
            "gap_id": gid,
            "pr_number": pr_num,
            "applied": apply_flag,
        }
        with open(ambient_file, "a", encoding="utf-8") as af:
            af.write(json.dumps(event, separators=(",", ":")) + "\n")
        if apply_flag:
            marker = f"[INFRA-1911] PR #{pr_num} is CLOSED without merge"
            if marker not in notes:
                new_notes = (notes + "\n" + marker).strip()
                scon.execute(
                    "UPDATE gaps SET notes = ? WHERE id = ?", (new_notes, gid)
                )
                notes = new_notes

if apply_flag and hits > 0:
    scon.commit()

sys.exit(1 if hits > 0 else 0)
PY
