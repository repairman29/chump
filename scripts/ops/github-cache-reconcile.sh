#!/usr/bin/env bash
# scripts/ops/github-cache-reconcile.sh — INFRA-1081
#
# Periodic reconciliation: ONE REST call fetches all open PRs, diffs against
# .chump/github_cache.db, and surfaces drift. Catches webhook deliveries we
# missed (smee outage, receiver crashed, network blip).
#
# Designed to run every 5 min via launchd. Cheap: 1 REST call per cycle.
#
# Usage:
#   scripts/ops/github-cache-reconcile.sh           # apply (drift surfaced + cache updated)
#   scripts/ops/github-cache-reconcile.sh --check   # report only, no DB writes
#
# Ambient events:
#   kind=cache_drift   per drift row found, with {pr_number, columns}

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../lib/resolve-main-worktree.sh
source "$SCRIPT_DIR/../lib/resolve-main-worktree.sh"
REPO="$(resolve_main_worktree "$0")"
cd "$REPO" || exit 1

CACHE_DB="${CHUMP_CACHE_DB:-$REPO/.chump/github_cache.db}"
AMBIENT="$REPO/.chump-locks/ambient.jsonl"
MODE="apply"
case "${1:-}" in
    --check) MODE="check" ;;
    "") ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
esac

mkdir -p "$(dirname "$CACHE_DB")" "$(dirname "$AMBIENT")" 2>/dev/null

# One REST call for all open PRs.
REPO_NWO="$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null)"
if [[ -z "$REPO_NWO" ]]; then
    echo "cache-reconcile: cannot resolve repo (gh repo view failed) — exit" >&2
    exit 0
fi

PRS_JSON="$(gh api "repos/$REPO_NWO/pulls?state=open&per_page=100" 2>/dev/null)"
if [[ -z "$PRS_JSON" || "$PRS_JSON" == "[]" ]]; then
    echo "cache-reconcile: no open PRs"
    exit 0
fi

DRIFT_COUNT=0
python3 - "$CACHE_DB" "$AMBIENT" "$MODE" "$PRS_JSON" <<'PY'
import json, sqlite3, sys
from datetime import datetime, timezone

db_path, ambient, mode, prs_raw = sys.argv[1:5]
prs = json.loads(prs_raw)
now = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

conn = sqlite3.connect(db_path)
conn.executescript("""
CREATE TABLE IF NOT EXISTS pr_state (
    number INTEGER PRIMARY KEY,
    head_ref TEXT, head_sha TEXT, base_ref TEXT, base_sha TEXT,
    mergeable_state TEXT,
    auto_merge_enabled INTEGER NOT NULL DEFAULT 0,
    draft INTEGER NOT NULL DEFAULT 0,
    merged_at TEXT, title TEXT, user_login TEXT,
    updated_at_api TEXT NOT NULL, fetched_at_local TEXT NOT NULL,
    raw_payload_json TEXT
);
CREATE INDEX IF NOT EXISTS pr_state_behind_armed ON pr_state(mergeable_state, auto_merge_enabled);
""")

drift_count = 0
for pr in prs:
    n = pr.get("number")
    row = conn.execute(
        "SELECT mergeable_state, auto_merge_enabled, head_sha, draft, merged_at FROM pr_state WHERE number = ?",
        (n,),
    ).fetchone()
    api_ms = pr.get("mergeable_state")
    api_am = 1 if pr.get("auto_merge") else 0
    api_sha = (pr.get("head") or {}).get("sha")
    api_dr = 1 if pr.get("draft") else 0
    api_merged = pr.get("merged_at")

    drifted_cols = []
    if row is None:
        drifted_cols = ["row_missing"]
    else:
        if row[0] != api_ms: drifted_cols.append(f"mergeable_state:{row[0]}→{api_ms}")
        if row[1] != api_am: drifted_cols.append(f"auto_merge_enabled:{row[1]}→{api_am}")
        if row[2] != api_sha: drifted_cols.append(f"head_sha:{row[2]}→{api_sha}")
        if row[3] != api_dr: drifted_cols.append(f"draft:{row[3]}→{api_dr}")
        if row[4] != api_merged: drifted_cols.append(f"merged_at:{row[4]}→{api_merged}")

    if drifted_cols:
        drift_count += 1
        try:
            with open(ambient, "a", encoding="utf-8") as f:
                f.write(json.dumps({
                    "ts": now,
                    "kind": "cache_drift",
                    "pr_number": n,
                    "columns": drifted_cols,
                }, separators=(",", ":")) + "\n")
        except Exception:
            pass
        if mode == "apply":
            conn.execute("""
            INSERT INTO pr_state VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?)
            ON CONFLICT(number) DO UPDATE SET
                head_ref=excluded.head_ref, head_sha=excluded.head_sha,
                base_ref=excluded.base_ref, base_sha=excluded.base_sha,
                mergeable_state=excluded.mergeable_state,
                auto_merge_enabled=excluded.auto_merge_enabled,
                draft=excluded.draft, merged_at=excluded.merged_at,
                title=excluded.title, user_login=excluded.user_login,
                updated_at_api=excluded.updated_at_api,
                fetched_at_local=excluded.fetched_at_local,
                raw_payload_json=excluded.raw_payload_json
            """, (
                n, (pr.get("head") or {}).get("ref"), api_sha,
                (pr.get("base") or {}).get("ref"), (pr.get("base") or {}).get("sha"),
                api_ms, api_am, api_dr, api_merged,
                pr.get("title"), (pr.get("user") or {}).get("login"),
                pr.get("updated_at") or now, now,
                json.dumps(pr),
            ))
            conn.commit()

print(f"cache-reconcile: mode={mode} open_prs={len(prs)} drift_rows={drift_count}")
PY
