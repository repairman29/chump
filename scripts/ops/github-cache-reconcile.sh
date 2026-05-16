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
AMBIENT="${CHUMP_AMBIENT_LOG:-$REPO/.chump-locks/ambient.jsonl}"
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
if [[ -z "$PRS_JSON" ]]; then
    # API call failed entirely — bail (different from "no open PRs").
    echo "cache-reconcile: gh api returned empty — exit"
    exit 0
fi
# INFRA-1106: don't early-exit on PRS_JSON=="[]" — the cold-start block in
# the python heredoc still has work to do (warming pr_state rows whose
# mergeable_state is empty, even when the bulk list returns no rows).
[[ "$PRS_JSON" == "[]" ]] && PRS_JSON="[]"

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
# INFRA-1368: add merge_state_status column idempotently.
try:
    conn.execute("ALTER TABLE pr_state ADD COLUMN merge_state_status TEXT")
    conn.commit()
except Exception:
    pass  # column already exists

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
            INSERT INTO pr_state (
                number, head_ref, head_sha, base_ref, base_sha,
                mergeable_state, auto_merge_enabled, draft, merged_at,
                title, user_login, updated_at_api, fetched_at_local,
                raw_payload_json, merge_state_status
            ) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
            ON CONFLICT(number) DO UPDATE SET
                head_ref=excluded.head_ref, head_sha=excluded.head_sha,
                base_ref=excluded.base_ref, base_sha=excluded.base_sha,
                mergeable_state=excluded.mergeable_state,
                auto_merge_enabled=excluded.auto_merge_enabled,
                draft=excluded.draft, merged_at=excluded.merged_at,
                title=excluded.title, user_login=excluded.user_login,
                updated_at_api=excluded.updated_at_api,
                fetched_at_local=excluded.fetched_at_local,
                raw_payload_json=excluded.raw_payload_json,
                merge_state_status=excluded.merge_state_status
            """, (
                n, (pr.get("head") or {}).get("ref"), api_sha,
                (pr.get("base") or {}).get("ref"), (pr.get("base") or {}).get("sha"),
                api_ms, api_am, api_dr, api_merged,
                pr.get("title"), (pr.get("user") or {}).get("login"),
                pr.get("updated_at") or now, now,
                json.dumps(pr),
                api_ms,  # INFRA-1368: populate merge_state_status from REST mergeable_state
            ))
            conn.commit()

print(f"cache-reconcile: mode={mode} open_prs={len(prs)} drift_rows={drift_count}")

# INFRA-1106: cold-start fill — bulk /pulls?state=open omits mergeable_state
# (GitHub computes it asynchronously). For rows where it's empty, do bounded
# per-PR REST fetches. Each fetch is 1 REST point; bounded by env var.
import os, subprocess
max_fetch = int(os.environ.get("CHUMP_CACHE_RECONCILE_MAX_FETCH", "20"))
repo_nwo = ""  # resolved lazily; shared by INFRA-1106 and INFRA-1129 blocks
if mode == "apply" and max_fetch > 0:
    cold_rows = conn.execute(
        "SELECT number FROM pr_state "
        "WHERE (mergeable_state IS NULL OR mergeable_state = '') "
        "  AND merged_at IS NULL "
        "ORDER BY number ASC LIMIT ?",
        (max_fetch,),
    ).fetchall()
    if cold_rows:
        try:
            repo_nwo = subprocess.check_output(
                ["gh", "repo", "view", "--json", "nameWithOwner", "-q", ".nameWithOwner"],
                text=True,
            ).strip()
        except Exception:
            repo_nwo = ""
        warmed = 0
        for (cold_n,) in cold_rows:
            if not repo_nwo:
                break
            try:
                r = subprocess.run(
                    ["gh", "api", f"repos/{repo_nwo}/pulls/{cold_n}"],
                    capture_output=True, text=True, timeout=20,
                )
                if r.returncode != 0:
                    continue
                pr_full = json.loads(r.stdout)
            except Exception:
                continue
            api_ms = pr_full.get("mergeable_state")
            if not api_ms:
                continue
            conn.execute("""
            INSERT INTO pr_state (
                number, head_ref, head_sha, base_ref, base_sha,
                mergeable_state, auto_merge_enabled, draft, merged_at,
                title, user_login, updated_at_api, fetched_at_local,
                raw_payload_json, merge_state_status
            ) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
            ON CONFLICT(number) DO UPDATE SET
                mergeable_state=excluded.mergeable_state,
                merge_state_status=excluded.merge_state_status,
                head_sha=excluded.head_sha,
                auto_merge_enabled=excluded.auto_merge_enabled,
                draft=excluded.draft,
                merged_at=excluded.merged_at,
                updated_at_api=excluded.updated_at_api,
                fetched_at_local=excluded.fetched_at_local,
                raw_payload_json=excluded.raw_payload_json
            """, (
                cold_n,
                (pr_full.get("head") or {}).get("ref"),
                (pr_full.get("head") or {}).get("sha"),
                (pr_full.get("base") or {}).get("ref"),
                (pr_full.get("base") or {}).get("sha"),
                api_ms,
                1 if pr_full.get("auto_merge") else 0,
                1 if pr_full.get("draft") else 0,
                pr_full.get("merged_at"),
                pr_full.get("title"),
                (pr_full.get("user") or {}).get("login"),
                pr_full.get("updated_at") or now,
                now,
                json.dumps(pr_full),
                api_ms,  # INFRA-1368: populate merge_state_status
            ))
            conn.commit()
            warmed += 1
            try:
                with open(ambient, "a", encoding="utf-8") as f:
                    f.write(json.dumps({
                        "ts": now, "kind": "cache_warmed",
                        "pr_number": cold_n, "mergeable_state": api_ms,
                    }, separators=(",", ":")) + "\n")
            except Exception:
                pass
        if warmed:
            print(f"cache-reconcile: warmed {warmed} cold rows (mergeable_state filled)")

# INFRA-1129: cold-start fill — check_runs table is empty for existing pr_state
# rows until webhook events fire for each SHA. Backfill via bounded REST fetches.
# One REST call per SHA; bounded by CHUMP_CACHE_RECONCILE_MAX_FETCH (same cap).
conn.executescript("""
CREATE TABLE IF NOT EXISTS check_runs (
    head_sha          TEXT NOT NULL,
    name              TEXT NOT NULL,
    status            TEXT,
    conclusion        TEXT,
    started_at        TEXT,
    completed_at      TEXT,
    fetched_at_local  TEXT NOT NULL,
    PRIMARY KEY (head_sha, name)
);
CREATE INDEX IF NOT EXISTS check_runs_sha ON check_runs(head_sha);
""")
if mode == "apply" and max_fetch > 0:
    cold_shas = conn.execute(
        "SELECT DISTINCT head_sha FROM pr_state "
        "WHERE head_sha IS NOT NULL AND head_sha != '' AND merged_at IS NULL "
        "  AND head_sha NOT IN (SELECT DISTINCT head_sha FROM check_runs) "
        "ORDER BY head_sha ASC LIMIT ?",
        (max_fetch,),
    ).fetchall()
    if cold_shas:
        try:
            if not repo_nwo:
                repo_nwo = subprocess.check_output(
                    ["gh", "repo", "view", "--json", "nameWithOwner", "-q", ".nameWithOwner"],
                    text=True,
                ).strip()
        except Exception:
            pass
        cr_warmed = 0
        for (sha,) in cold_shas:
            if not repo_nwo:
                break
            try:
                r = subprocess.run(
                    ["gh", "api", f"repos/{repo_nwo}/commits/{sha}/check-runs",
                     "--jq", ".check_runs"],
                    capture_output=True, text=True, timeout=20,
                )
                if r.returncode != 0:
                    continue
                runs = json.loads(r.stdout)
            except Exception:
                continue
            if not isinstance(runs, list):
                continue
            count = 0
            for run in runs:
                name = run.get("name")
                if not name:
                    continue
                conn.execute(
                    """
                    INSERT INTO check_runs (head_sha, name, status, conclusion, started_at, completed_at, fetched_at_local)
                    VALUES (?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(head_sha, name) DO UPDATE SET
                        status           = excluded.status,
                        conclusion       = excluded.conclusion,
                        started_at       = excluded.started_at,
                        completed_at     = excluded.completed_at,
                        fetched_at_local = excluded.fetched_at_local
                    """,
                    (sha, name, run.get("status"), run.get("conclusion"),
                     run.get("started_at"), run.get("completed_at"), now),
                )
                count += 1
            if count:
                conn.commit()
                cr_warmed += 1
                try:
                    with open(ambient, "a", encoding="utf-8") as f:
                        f.write(json.dumps({
                            "ts": now, "kind": "check_runs_warmed",
                            "head_sha": sha, "count": count,
                        }, separators=(",", ":")) + "\n")
                except Exception:
                    pass
        if cr_warmed:
            print(f"cache-reconcile: warmed {cr_warmed} SHAs (check_runs backfilled)")
PY
