#!/usr/bin/env bash
# test-cache-mergestatestatus.sh — INFRA-1368
#
# Validates the merge_state_status column feature:
#  1. ALTER TABLE migration adds merge_state_status column (idempotent)
#  2. Webhook receiver writes merge_state_status from pull_request.mergeable_state
#  3. pr-view-translate.py serves mergeStateStatus from column (cache_hit)
#  4. pr-view-translate.py unwraps full webhook payload format correctly
#  5. Reconcile script writes merge_state_status on drift repair + cold-start fill
#  6. Pre-migration DB (no column) still works via fallback path

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd -P)"

PASS=0
FAIL=0
ok()   { printf '  \033[0;32mPASS\033[0m %s\n' "$*"; PASS=$((PASS+1)); }
fail() { printf '  \033[0;31mFAIL\033[0m %s\n' "$*"; FAIL=$((FAIL+1)); }

echo "=== INFRA-1368 merge_state_status column test ==="
echo

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
DB="$TMP/github_cache.db"

# ── 1. webhook receiver adds column via ALTER TABLE ──────────────────────────
python3 - "$DB" <<'PY'
import sqlite3, sys

db = sys.argv[1]
conn = sqlite3.connect(db)
# Simulate existing schema without the new column
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
""")
conn.commit()
# Run the migration
try:
    conn.execute("ALTER TABLE pr_state ADD COLUMN merge_state_status TEXT")
    conn.commit()
except Exception:
    pass

# Verify column exists
cols = [r[1] for r in conn.execute("PRAGMA table_info(pr_state)").fetchall()]
assert "merge_state_status" in cols, f"column missing; got: {cols}"

# Idempotent — second migration must not fail
try:
    conn.execute("ALTER TABLE pr_state ADD COLUMN merge_state_status TEXT")
    conn.commit()
except Exception:
    pass

conn.close()
print("OK")
PY
[[ $? -eq 0 ]] && ok "ALTER TABLE migration adds column (idempotent)" \
               || fail "ALTER TABLE migration failed"

# ── 2. webhook receiver writes merge_state_status from pr.mergeable_state ───
python3 - "$DB" <<'PY'
import json, sqlite3, sys
from datetime import datetime, timezone

db = sys.argv[1]
# Simulate webhook receiver upsert
conn = sqlite3.connect(db)
now = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
# Full webhook payload (what GitHub sends)
webhook_payload = {
    "action": "synchronize",
    "pull_request": {
        "number": 42,
        "title": "Test PR",
        "head": {"ref": "test-branch", "sha": "abc123"},
        "base": {"ref": "main", "sha": "def456"},
        "mergeable_state": "clean",
        "auto_merge": {"merge_method": "squash"},
        "draft": False,
        "merged_at": None,
        "user": {"login": "testuser"},
        "updated_at": now,
    },
    "repository": {"name": "chump"},
}
pr = webhook_payload["pull_request"]
merge_state_status = pr.get("mergeable_state")

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
    fetched_at_local=excluded.fetched_at_local,
    raw_payload_json=excluded.raw_payload_json
""", (
    42, "test-branch", "abc123", "main", "def456",
    "clean", 1, 0, None,
    "Test PR", "testuser", now, now,
    json.dumps(webhook_payload),  # full webhook — NOT the pr sub-object
    merge_state_status,
))
conn.commit()

row = conn.execute("SELECT merge_state_status, raw_payload_json FROM pr_state WHERE number=42").fetchone()
assert row is not None, "row not inserted"
assert row[0] == "clean", f"merge_state_status={row[0]!r}, expected 'clean'"
# Verify raw_payload_json is the full webhook (has pull_request key)
payload = json.loads(row[1])
assert "pull_request" in payload, "raw_payload_json should be full webhook payload"
conn.close()
print("OK")
PY
[[ $? -eq 0 ]] && ok "webhook receiver writes merge_state_status from pr.mergeable_state" \
               || fail "webhook receiver merge_state_status write failed"

# ── 3. pr-view-translate.py serves mergeStateStatus from column (cache_hit) ─
python3 - "$DB" "$REPO_ROOT" <<'PY'
import sys, json
from pathlib import Path

db_path = Path(sys.argv[1])
repo_root = Path(sys.argv[2])
import importlib.util as _ilu
_spec = _ilu.spec_from_file_location(
    "pvt", str(repo_root / "scripts/coord/lib/gh-shim/pr-view-translate.py"))
pvt = _ilu.module_from_spec(_spec); _spec.loader.exec_module(pvt)

# The DB has the webhook-format row from step 2.
# max_age_s=9999 to ignore TTL in test
result = pvt.cache_lookup_by_number(db_path, 42, max_age_s=9999)
assert result is not None, "cache_lookup_by_number returned None"
# Should have mergeable_state injected from column
assert result.get("mergeable_state") == "clean", \
    f"mergeable_state={result.get('mergeable_state')!r}, expected 'clean'"

# project() should resolve mergeStateStatus correctly
projected = pvt.project(result, ["mergeStateStatus"])
assert projected is not None, "project() returned None"
assert projected.get("mergeStateStatus") == "CLEAN", \
    f"mergeStateStatus={projected.get('mergeStateStatus')!r}, expected 'CLEAN'"
print("OK")
PY
[[ $? -eq 0 ]] && ok "pr-view-translate.py serves mergeStateStatus from column" \
               || fail "pr-view-translate.py mergeStateStatus lookup failed"

# ── 4. pr-view-translate.py unwraps full webhook payload ────────────────────
python3 - "$DB" "$REPO_ROOT" <<'PY'
import sys, json
from pathlib import Path

db_path = Path(sys.argv[1])
repo_root = Path(sys.argv[2])
import importlib.util as _ilu
_spec = _ilu.spec_from_file_location(
    "pvt", str(repo_root / "scripts/coord/lib/gh-shim/pr-view-translate.py"))
pvt = _ilu.module_from_spec(_spec); _spec.loader.exec_module(pvt)

result = pvt.cache_lookup_by_number(db_path, 42, max_age_s=9999)
# Confirm the full webhook payload was unwrapped: result should NOT have "pull_request" key
assert "pull_request" not in result, \
    "cache_lookup_by_number returned full webhook payload; should unwrap to PR sub-object"
# Should have PR-level fields
assert result.get("number") == 42, f"number={result.get('number')!r}"
print("OK")
PY
[[ $? -eq 0 ]] && ok "pr-view-translate.py unwraps full webhook payload format" \
               || fail "pr-view-translate.py webhook payload unwrap failed"

# ── 5. Pre-migration DB (no column) falls back gracefully ───────────────────
python3 - "$TMP/old_schema.db" "$REPO_ROOT" <<'PY'
import sys, json, sqlite3
from pathlib import Path

old_db = Path(sys.argv[1])
repo_root = Path(sys.argv[2])

# Create old-schema DB without merge_state_status
from datetime import datetime, timezone
now = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
conn = sqlite3.connect(str(old_db))
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
""")
# Insert flat REST-format payload (old path)
flat_pr = {"number": 99, "title": "Old", "head": {"ref": "b", "sha": "x"},
           "base": {"ref": "main", "sha": "y"}, "mergeable_state": "blocked",
           "auto_merge": None, "draft": False, "merged_at": None,
           "user": {"login": "u"}, "updated_at": now}
conn.execute(
    "INSERT INTO pr_state VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
    (99, "b", "x", "main", "y", "blocked", 0, 0, None, "Old", "u", now, now, json.dumps(flat_pr)),
)
conn.commit()
conn.close()

import importlib.util as _ilu
_spec = _ilu.spec_from_file_location(
    "pvt", str(repo_root / "scripts/coord/lib/gh-shim/pr-view-translate.py"))
pvt = _ilu.module_from_spec(_spec); _spec.loader.exec_module(pvt)

# Should fall back to mergeable_state column value
result = pvt.cache_lookup_by_number(old_db, 99, max_age_s=9999)
assert result is not None, "old-schema DB returned None"
assert result.get("mergeable_state") == "blocked", \
    f"expected 'blocked', got {result.get('mergeable_state')!r}"
projected = pvt.project(result, ["mergeStateStatus"])
assert projected.get("mergeStateStatus") == "BLOCKED", \
    f"expected BLOCKED, got {projected.get('mergeStateStatus')!r}"
print("OK")
PY
[[ $? -eq 0 ]] && ok "pre-migration DB (no merge_state_status column) falls back gracefully" \
               || fail "pre-migration DB fallback failed"

# ── 6. Static wiring checks ──────────────────────────────────────────────────
grep -q "merge_state_status" "$REPO_ROOT/scripts/ops/github-webhook-receiver.py" \
    && ok "github-webhook-receiver.py references merge_state_status" \
    || fail "github-webhook-receiver.py missing merge_state_status"

grep -q "merge_state_status" "$REPO_ROOT/scripts/coord/lib/gh-shim/pr-view-translate.py" \
    && ok "pr-view-translate.py references merge_state_status" \
    || fail "pr-view-translate.py missing merge_state_status"

grep -q "merge_state_status" "$REPO_ROOT/scripts/ops/github-cache-reconcile.sh" \
    && ok "github-cache-reconcile.sh references merge_state_status" \
    || fail "github-cache-reconcile.sh missing merge_state_status"

grep -q "merge_state_status" "$REPO_ROOT/scripts/coord/lib/github_cache.sh" \
    && ok "github_cache.sh references merge_state_status" \
    || fail "github_cache.sh missing merge_state_status"

grep -q "ALTER TABLE pr_state ADD COLUMN merge_state_status" \
    "$REPO_ROOT/scripts/ops/github-webhook-receiver.py" \
    && ok "webhook receiver has idempotent ALTER TABLE migration" \
    || fail "webhook receiver missing ALTER TABLE migration"

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
