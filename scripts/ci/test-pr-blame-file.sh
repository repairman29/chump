#!/usr/bin/env bash
# test-pr-blame-file.sh — INFRA-1445
#
# Validates `chump pr blame-file <path>`:
#  1. src/pr_blame_file.rs exists and exports the expected symbols
#  2. main.rs wires `chump pr blame-file`
#  3. Runtime: fabricates a github_cache.db with a squash-merged PR whose
#     raw_payload_json.files touches a path that git log alone doesn't
#     attribute — asserts blame-file surfaces it (the INFRA-1445 motivating
#     scenario).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd -P)"
CHUMP="${CHUMP:-$REPO_ROOT/target/debug/chump}"
SRC="$REPO_ROOT/src/pr_blame_file.rs"

PASS=0; FAIL=0; FAILS=()
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); FAILS+=("$1"); }

echo "=== INFRA-1445 chump pr blame-file tests ==="

[[ -f "$SRC" ]] && ok "src/pr_blame_file.rs exists" || { fail "missing src/pr_blame_file.rs"; exit 1; }

for sym in \
    "pub struct BlameReport" \
    "pub struct BlameRow" \
    "pub fn build_report" \
    "pub fn render_text" \
    "pub fn run" \
    "raw_payload_json"; do
    if grep -q "$sym" "$SRC"; then ok "exports/uses $sym"; else fail "missing $sym"; fi
done

if grep -q "^mod pr_blame_file;" "$REPO_ROOT/src/main.rs"; then
    ok "main.rs declares mod pr_blame_file"
else
    fail "main.rs missing mod pr_blame_file"
fi

if grep -q '"blame-file"' "$REPO_ROOT/src/main.rs"; then
    ok "main.rs wires chump pr blame-file"
else
    fail "main.rs missing blame-file CLI wiring"
fi

# ── Runtime: fabricated github_cache.db, squash-merge cross-ref ────────────
if [[ ! -x "$CHUMP" ]]; then
    echo "SKIP: chump binary not found at $CHUMP — build first (cargo build)"
else
    TMP="$(mktemp -d)"
    trap 'rm -rf "$TMP"' EXIT
    WT="$TMP/repo"
    mkdir -p "$WT/.chump" "$WT/scripts/ci"
    (
        cd "$WT"
        git init -q
        git config user.email test@test.local
        git config user.name test
        echo "old content" > scripts/ci/test-blamed-file.sh
        git add scripts/ci/test-blamed-file.sh
        git commit -q -m "INFRA-9001: add file (#9001)"
    )
    DB="$WT/.chump/github_cache.db"
    python3 - "$DB" <<'PY'
import json, sqlite3, sys

db = sys.argv[1]
conn = sqlite3.connect(db)
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
# A squash-merged PR whose diff touched the path but is NOT reflected in
# the file's own git-log history (the INFRA-1445 motivating scenario:
# git log -- <path> misses this landing).
payload = {
    "number": 9042,
    "title": "INFRA-9042: actually fix the blamed file",
    "files": [
        {"filename": "scripts/ci/test-blamed-file.sh"},
        {"filename": "other/unrelated.rs"},
    ],
}
conn.execute(
    "INSERT INTO pr_state (number, head_ref, head_sha, base_ref, base_sha, "
    "mergeable_state, auto_merge_enabled, draft, merged_at, title, "
    "user_login, updated_at_api, fetched_at_local, raw_payload_json) "
    "VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
    (9042, "fix-branch", "deadbeef1234", "main", "cafebabe",
     "clean", 0, 0, "2026-08-20T00:00:00Z", payload["title"],
     "testuser", "2026-08-20T00:00:00Z", "2026-08-20T00:00:00Z",
     json.dumps(payload)),
)
conn.commit()
conn.close()
print("OK")
PY
    if [[ $? -eq 0 ]]; then
        ok "fabricated github_cache.db with squash-merge cross-ref"
    else
        fail "failed to fabricate github_cache.db"
    fi

    OUT="$(cd "$WT" && CHUMP_REPO="$WT" "$CHUMP" pr blame-file scripts/ci/test-blamed-file.sh --json 2>&1)"
    if echo "$OUT" | python3 -c "
import json, sys
try:
    d = json.load(sys.stdin)
except Exception as e:
    print(f'PARSE_FAIL: {e}')
    sys.exit(1)
rows = d.get('rows', [])
prs = [r.get('landed_pr') for r in rows]
sources = [r.get('source') for r in rows]
gap_ids = [r.get('landed_gap_id') for r in rows]
ok_git = 9001 in prs
ok_cache = 9042 in prs and 'github_pr_cache' in sources
ok_gap = 'INFRA-9042' in gap_ids
sys.exit(0 if (ok_git and ok_cache and ok_gap) else 1)
"; then
        ok "blame-file finds both git-log commit (#9001) and cache-only squash-merge (#9042)"
    else
        fail "blame-file did not surface both sources; output: $OUT"
    fi

    OUT_TEXT="$(cd "$WT" && CHUMP_REPO="$WT" "$CHUMP" pr blame-file scripts/ci/test-blamed-file.sh 2>&1)"
    if echo "$OUT_TEXT" | grep -q "#9042" && echo "$OUT_TEXT" | grep -q "github_pr_cache"; then
        ok "text output includes cache-sourced row"
    else
        fail "text output missing cache-sourced row; output: $OUT_TEXT"
    fi
fi

echo
echo "=== $PASS passed, $FAIL failed ==="
if [[ $FAIL -gt 0 ]]; then
    for f in "${FAILS[@]}"; do echo "  FAILED: $f"; done
    exit 1
fi
exit 0
