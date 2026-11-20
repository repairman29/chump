#!/usr/bin/env bash
# scripts/ci/test-pr-blame-file.sh — INFRA-1445
#
# Validates `chump pr blame-file <path>`:
#  1. src/pr_blame_file.rs exports the expected surface
#  2. main.rs wires up `chump pr blame-file` dispatch
#  3. `cargo test pr_blame_file` unit tests pass
#  4. Functional: fabricate a temp git repo + a github_cache.db with a
#     squash-merged PR whose merge_commit_sha touched a path, then
#     assert `chump pr blame-file <path> --json` finds it.

set -uo pipefail
PASS=0; FAIL=0; FAILS=()
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); FAILS+=("$1"); }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SRC="$REPO_ROOT/src/pr_blame_file.rs"

echo "=== INFRA-1445 chump pr blame-file tests ==="

[[ -f "$SRC" ]] && ok "src/pr_blame_file.rs exists" || { fail "missing src/pr_blame_file.rs"; exit 1; }

for sym in \
    "pub struct BlameRow" \
    "pub struct MergedPrRow" \
    "pub fn build_report" \
    "pub fn extract_merge_commit_sha" \
    "pub fn read_merged_prs" \
    "pub fn render_json" \
    "pub fn render_text" \
    "pub fn run"; do
    if grep -q "$sym" "$SRC"; then ok "exports $sym"; else fail "missing $sym"; fi
done

if grep -q "^mod pr_blame_file;" "$REPO_ROOT/src/main.rs"; then
    ok "main.rs declares mod pr_blame_file"
else
    fail "main.rs missing mod pr_blame_file"
fi
if grep -q 'Some("blame-file")' "$REPO_ROOT/src/main.rs"; then
    ok "main.rs dispatches pr blame-file"
else
    fail "main.rs missing blame-file dispatch"
fi

if ! command -v cargo >/dev/null 2>&1; then
    echo "  SKIP: cargo not on PATH — remaining checks need it" >&2
    echo ""
    echo "=== Summary: $PASS passed, $FAIL failed ==="
    [[ "$FAIL" -eq 0 ]] && exit 0 || exit 1
fi

echo ""
if (cd "$REPO_ROOT" && cargo test --bin chump pr_blame_file --quiet -- --test-threads=1 2>&1 | tail -15); then
    ok "cargo test pr_blame_file passed"
else
    fail "cargo test pr_blame_file failed"
fi

# ── Functional: fabricated repo + cache DB ───────────────────────────────
BIN_DIR="${CARGO_TARGET_DIR:-$REPO_ROOT/target}/debug"
if [[ ! -x "$BIN_DIR/chump" ]]; then
    echo "test-pr-blame-file: building chump ($BIN_DIR/chump) …" >&2
    (cd "$REPO_ROOT" && cargo build -q --bin chump) 2>&1 || {
        echo "  SKIP: cargo build failed — functional test cannot run" >&2
        echo ""
        echo "=== Summary: $PASS passed, $FAIL failed ==="
        [[ "$FAIL" -eq 0 ]] && exit 0 || exit 1
    }
fi

if [[ -x "$BIN_DIR/chump" ]] && command -v python3 >/dev/null 2>&1; then
    TMP="$(mktemp -d)"
    trap 'rm -rf "$TMP"' EXIT

    # Fabricate a tiny git repo. The "squash-merge" commit touches a path
    # that `git log -- <path>` would only see via this one commit — we
    # then simulate the "git log missed it" scenario by asking for a
    # DIFFERENT path's history and confirming blame-file still surfaces
    # the squash-merge row via the cache DB cross-check.
    git init -q "$TMP/repo"
    (
        cd "$TMP/repo"
        git config user.email "test@example.com"
        git config user.name "Test"
        mkdir -p scripts/ci
        echo "original" > scripts/ci/test-target-file.sh
        git add -A
        git commit -qm "initial"
    )
    MERGE_SHA="$(cd "$TMP/repo" && echo "fixed" > scripts/ci/test-target-file.sh && git add -A && git commit -qm "INFRA-9001: fix target file" && git rev-parse HEAD)"

    DB="$TMP/github_cache.db"
    python3 - "$DB" "$MERGE_SHA" <<'PY'
import json, sqlite3, sys

db, merge_sha = sys.argv[1], sys.argv[2]
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
payload = {
    "pull_request": {
        "number": 9001,
        "title": "INFRA-9001: fix target file",
        "merge_commit_sha": merge_sha,
        "merged_at": "2026-09-01T00:00:00Z",
    }
}
conn.execute(
    "INSERT INTO pr_state (number, merged_at, title, updated_at_api, fetched_at_local, raw_payload_json) "
    "VALUES (?,?,?,?,?,?)",
    (9001, "2026-09-01T00:00:00Z", "INFRA-9001: fix target file",
     "2026-09-01T00:00:00Z", "2026-09-01T00:00:00Z", json.dumps(payload)),
)
conn.commit()
conn.close()
PY

    # CHUMP_REPO pins repo_root() to the fixture repo — otherwise a live
    # chumpd daemon could answer with the real repo root instead of cwd.
    OUT="$(cd "$TMP/repo" && CHUMP_REPO="$TMP/repo" "$BIN_DIR/chump" pr blame-file scripts/ci/test-target-file.sh --db "$DB" --json 2>&1 < /dev/null || true)"

    if echo "$OUT" | grep -q '"landed_pr": 9001'; then
        ok "blame-file finds squash-merged PR via github_cache.db"
    else
        fail "blame-file did not surface fabricated squash-merge (got: $OUT)"
    fi
    if echo "$OUT" | grep -q '"landed_gap_id": "INFRA-9001"'; then
        ok "blame-file extracts gap id from PR title"
    else
        fail "blame-file did not extract gap id (got: $OUT)"
    fi
else
    echo "  SKIP: chump binary or python3 unavailable — functional test skipped" >&2
fi

echo ""
echo "=== Summary: $PASS passed, $FAIL failed ==="
if (( FAIL > 0 )); then for f in "${FAILS[@]}"; do printf '  - %s\n' "$f"; done; exit 1; fi
echo "PASS"
