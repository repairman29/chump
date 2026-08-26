#!/usr/bin/env bash
# scripts/ci/test-pr-blame-file.sh — INFRA-1445

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
    "pub struct BlameReport" \
    "pub struct BlameRow" \
    "pub fn build_report" \
    "pub fn render_text" \
    "pub fn run" \
    "cache_row_touches_path"; do
    if grep -q "$sym" "$SRC"; then ok "exports $sym"; else fail "missing $sym"; fi
done

if grep -q "^mod pr_blame_file;" "$REPO_ROOT/src/main.rs"; then
    ok "main.rs declares mod pr_blame_file"
else
    fail "main.rs missing pr_blame_file"
fi
if grep -q 'Some("blame-file")' "$REPO_ROOT/src/main.rs"; then
    ok "main.rs dispatches pr blame-file"
else
    fail "main.rs missing blame-file dispatch"
fi

if command -v cargo >/dev/null 2>&1 && [[ -f "$REPO_ROOT/Cargo.toml" ]]; then
    echo ""
    if (cd "$REPO_ROOT" && cargo test --bin chump pr_blame_file --quiet -- --test-threads=1 2>&1 | tail -20); then
        ok "cargo test pr_blame_file passed"
    else
        fail "cargo test pr_blame_file failed"
    fi
fi

# End-to-end: fabricate a github_cache.db with a squash-merge PR whose
# raw_payload_json says it touched a path that plain `git log -- path`
# on a fresh one-commit repo has no history for at all — asserts
# blame-file finds it via the cache-only cross-ref path.
if command -v sqlite3 >/dev/null 2>&1 && command -v cargo >/dev/null 2>&1; then
    echo ""
    BIN="${CHUMP_BIN:-$REPO_ROOT/target/debug/chump}"
    if [[ ! -x "$BIN" ]]; then
        echo "  (building chump binary for e2e check...)"
        (cd "$REPO_ROOT" && cargo build --bin chump --quiet 2>&1 | tail -20)
    fi

    if [[ -x "$BIN" ]]; then
        TMPDIR_E2E="$(mktemp -d)"
        trap 'rm -rf "$TMPDIR_E2E"' EXIT
        (
            cd "$TMPDIR_E2E"
            git init -q
            git config user.email "test@example.com"
            git config user.name "test"
            mkdir -p scripts/ci
            echo "echo v1" > scripts/ci/test-cache-mergestatestatus.sh
            git add scripts/ci/test-cache-mergestatestatus.sh
            git commit -q -m "init: unrelated commit, no fix here"

            mkdir -p .chump
            sqlite3 .chump/github_cache.db <<'SQL'
CREATE TABLE pr_state (
    number              INTEGER PRIMARY KEY,
    head_ref            TEXT,
    head_sha            TEXT,
    base_ref            TEXT,
    base_sha            TEXT,
    mergeable_state     TEXT,
    auto_merge_enabled  INTEGER NOT NULL DEFAULT 0,
    draft               INTEGER NOT NULL DEFAULT 0,
    merged_at           TEXT,
    title               TEXT,
    user_login          TEXT,
    updated_at_api      TEXT NOT NULL,
    fetched_at_local    TEXT NOT NULL,
    raw_payload_json    TEXT,
    merge_state_status  TEXT
);
INSERT INTO pr_state (number, merged_at, title, updated_at_api, fetched_at_local, raw_payload_json)
VALUES (
    2130,
    '2026-05-03T12:00:00Z',
    'INFRA-1383: unrelated title, patch touched the file',
    '2026-05-03T12:00:00Z',
    '2026-05-03T12:00:00Z',
    '{"merge_commit_sha":"deadbeefcafe","files":["scripts/ci/test-cache-mergestatestatus.sh"],"body":"Closes INFRA-1383"}'
);
SQL
        )
        OUT="$(cd "$TMPDIR_E2E" && CHUMP_REPO="$TMPDIR_E2E" CHUMP_HOME="$TMPDIR_E2E" "$BIN" pr blame-file scripts/ci/test-cache-mergestatestatus.sh --json 2>&1)"
        if echo "$OUT" | grep -q '"landed_pr": 2130' && echo "$OUT" | grep -q 'INFRA-1383' && echo "$OUT" | grep -q 'cache_only'; then
            ok "e2e: fabricated squash-merge PR #2130 surfaced via cache-only cross-ref"
        else
            fail "e2e: blame-file did not surface fabricated PR #2130 (output: $OUT)"
        fi
    else
        echo "  (skip e2e: could not build chump binary)"
    fi
fi

echo ""
echo "=== Summary: $PASS passed, $FAIL failed ==="
if (( FAIL > 0 )); then for f in "${FAILS[@]}"; do printf '  - %s\n' "$f"; done; exit 1; fi
echo "PASS"
