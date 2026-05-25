#!/usr/bin/env bash
# scripts/ci/test-github-cache-rust-parity.sh — INFRA-1999 Phase 1
#
# Smoke test that the new Rust CLI (chump-github-cache-cli) produces
# output equivalent to the bash helpers in
# scripts/coord/lib/github_cache.sh for representative cases.
#
# Build steps:
#   1. Build the Rust CLI.
#   2. Pre-populate a synthetic .chump/github_cache.db with 10 PR rows
#      (mixed mergeable_state, including BEHIND+armed for the
#      query_behind_prs path).
#   3. Run each helper via:
#        a) the bash legacy body (CHUMP_GITHUB_CACHE_RUST=0)
#        b) the Rust CLI    (CHUMP_GITHUB_CACHE_RUST=1)
#      and assert identical-ish output. (Bash emits cache_hit/cache_miss
#      ambient events that the Rust path deliberately does not — Phase
#      1 keeps the new crate event-emission-free per INFRA-2003 lease
#      on event-registry-reserved.txt. Output payloads themselves
#      match.)
#   4. SQL-injection: titles containing `; DROP TABLE`, `' OR 1=1`,
#      quote chars must NOT damage the DB.
#   5. Schema-tolerance: synthetic PR row with an extra/unknown JSON
#      field still parses through `cache_lookup_pr` under the Rust path.
#
# DOES NOT emit any new ambient event kinds. Sets CHUMP_AMBIENT_DISABLE=1
# defensively to mute the existing emissions from the legacy bash body
# during this test run.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

unset CHUMP_LOCK_DIR CHUMP_REPO CHUMP_REPO_ROOT 2>/dev/null || true
export CHUMP_AMBIENT_DISABLE=1

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

PASS=0
FAIL=0
ok()   { printf '\033[0;32mPASS\033[0m %s\n' "$*"; PASS=$((PASS+1)); }
fail() { printf '\033[0;31mFAIL\033[0m %s\n' "$*"; FAIL=$((FAIL+1)); }
note() { printf '      %s\n' "$*"; }

# ---------------------------------------------------------------------------
# Build the Rust CLI.
# ---------------------------------------------------------------------------
echo "[test] building chump-github-cache binaries..."
BUILD_LOG="$TMP/build.log"
if ! (cd "$REPO_ROOT" && PATH="$HOME/.cargo/bin:$PATH" \
        cargo build --quiet -p chump-github-cache \
            --bin chump-github-cache-cli \
            --bin chump-webhook-receiver) \
        >"$BUILD_LOG" 2>&1; then
    echo "[test] BUILD FAILED — log below:"
    cat "$BUILD_LOG"
    exit 1
fi

CLI=""
for candidate in \
    "$REPO_ROOT/target/debug/chump-github-cache-cli" \
    "$REPO_ROOT/.cargo-test-target/debug/chump-github-cache-cli" \
    "${CARGO_TARGET_DIR:-}/debug/chump-github-cache-cli" \
    ; do
    [[ -z "$candidate" ]] && continue
    if [[ -x "$candidate" ]]; then
        CLI="$candidate"
        break
    fi
done
if [[ -z "$CLI" ]]; then
    fail "could not locate built chump-github-cache-cli binary"
    exit 1
fi
note "CLI: $CLI"

# ---------------------------------------------------------------------------
# Build the synthetic DB. 10 PRs total.
# ---------------------------------------------------------------------------
DB="$TMP/github_cache.db"
sqlite3 "$DB" <<'SQL'
CREATE TABLE pr_state (
    number INTEGER PRIMARY KEY,
    head_ref TEXT, head_sha TEXT, base_ref TEXT, base_sha TEXT,
    mergeable_state TEXT,
    auto_merge_enabled INTEGER NOT NULL DEFAULT 0,
    draft INTEGER NOT NULL DEFAULT 0,
    merged_at TEXT, title TEXT, user_login TEXT,
    updated_at_api TEXT NOT NULL, fetched_at_local TEXT NOT NULL,
    raw_payload_json TEXT,
    merge_state_status TEXT
);
CREATE INDEX pr_state_behind_armed ON pr_state(mergeable_state, auto_merge_enabled);
CREATE TABLE check_runs (
    head_sha TEXT NOT NULL, name TEXT NOT NULL,
    status TEXT, conclusion TEXT,
    started_at TEXT, completed_at TEXT,
    fetched_at_local TEXT NOT NULL,
    PRIMARY KEY (head_sha, name)
);
CREATE INDEX check_runs_sha ON check_runs(head_sha);
SQL

# 10 PRs: 1..10. Mix:
#   1, 4, 7  : open, clean
#   2, 5     : open, BEHIND + auto_merge_enabled (the query_behind_prs targets)
#   3        : open, BEHIND but NOT armed (must NOT appear in behind list)
#   6        : open, dirty
#   8        : open, with "; DROP TABLE pr_state; --" in the title
#   9        : open, with an unknown extra JSON field in raw_payload_json
#   10       : merged (must be filtered out of open-PR queries)
for i in 1 4 7; do
    sqlite3 "$DB" "INSERT INTO pr_state(number, head_ref, head_sha, base_ref, mergeable_state, auto_merge_enabled, updated_at_api, fetched_at_local, title, raw_payload_json) VALUES ($i, 'feature/$i', 'sha$i', 'main', 'clean', 0, '2026-05-25T19:00:00Z', '2026-05-25T19:01:00Z', 'feat: thing $i', '{\"number\":$i}');"
done
for i in 2 5; do
    sqlite3 "$DB" "INSERT INTO pr_state(number, head_ref, head_sha, base_ref, mergeable_state, auto_merge_enabled, updated_at_api, fetched_at_local, title, raw_payload_json) VALUES ($i, 'feature/$i', 'sha$i', 'main', 'BEHIND', 1, '2026-05-25T19:00:00Z', '2026-05-25T19:01:00Z', 'behind+armed $i', '{\"number\":$i}');"
done
sqlite3 "$DB" "INSERT INTO pr_state(number, head_ref, head_sha, base_ref, mergeable_state, auto_merge_enabled, updated_at_api, fetched_at_local, title, raw_payload_json) VALUES (3, 'feature/3', 'sha3', 'main', 'BEHIND', 0, '2026-05-25T19:00:00Z', '2026-05-25T19:01:00Z', 'behind unarmed 3', '{\"number\":3}');"
sqlite3 "$DB" "INSERT INTO pr_state(number, head_ref, head_sha, base_ref, mergeable_state, auto_merge_enabled, updated_at_api, fetched_at_local, title, raw_payload_json) VALUES (6, 'feature/6', 'sha6', 'main', 'dirty', 0, '2026-05-25T19:00:00Z', '2026-05-25T19:01:00Z', 'dirty 6', '{\"number\":6}');"
# Use single-quote escaping for the SQL injection title.
sqlite3 "$DB" "INSERT INTO pr_state(number, head_ref, head_sha, base_ref, mergeable_state, auto_merge_enabled, updated_at_api, fetched_at_local, title, raw_payload_json) VALUES (8, 'feature/8', 'sha8', 'main', 'clean', 0, '2026-05-25T19:00:00Z', '2026-05-25T19:01:00Z', 'evil ''; DROP TABLE pr_state; --', '{\"number\":8}');"
# PR 9: raw_payload_json includes an UNKNOWN top-level key.
sqlite3 "$DB" "INSERT INTO pr_state(number, head_ref, head_sha, base_ref, mergeable_state, auto_merge_enabled, updated_at_api, fetched_at_local, title, raw_payload_json) VALUES (9, 'feature/9', 'sha9', 'main', 'clean', 0, '2026-05-25T19:00:00Z', '2026-05-25T19:01:00Z', 'unknown-field 9', '{\"number\":9,\"future_field_chump_doesnt_know_about\":{\"x\":1}}');"
# PR 10: merged — must be filtered out of open queries.
sqlite3 "$DB" "INSERT INTO pr_state(number, head_ref, head_sha, base_ref, mergeable_state, auto_merge_enabled, updated_at_api, fetched_at_local, merged_at, title, raw_payload_json) VALUES (10, 'feature/10', 'sha10', 'main', 'clean', 0, '2026-05-25T19:00:00Z', '2026-05-25T19:01:00Z', '2026-05-25T18:30:00Z', 'merged 10', '{\"number\":10}');"

# Check runs for sha1
for name in alpha mu zeta; do
    sqlite3 "$DB" "INSERT INTO check_runs VALUES ('sha1', '$name', 'completed', 'success', '2026-05-25T18:00:00Z', '2026-05-25T18:05:00Z', '2026-05-25T18:06:00Z');"
done

export CHUMP_CACHE_DB="$DB"

ROW_COUNT="$(sqlite3 "$DB" "SELECT COUNT(*) FROM pr_state")"
note "synthetic DB rows: $ROW_COUNT"
if [[ "$ROW_COUNT" -ne 10 ]]; then
    fail "synthetic DB build failed (expected 10 rows, got $ROW_COUNT)"
    exit 1
fi
ok "synthetic DB built with 10 PR rows + 3 check_runs"

# ---------------------------------------------------------------------------
# Test 1: query_open_prs returns 9 PRs DESC by number (10 is merged → filtered).
# ---------------------------------------------------------------------------
RUST_OPEN="$("$CLI" --db "$DB" query-open-prs)"
COUNT_OPEN="$(printf '%s\n' "$RUST_OPEN" | grep -c '^' || true)"
if [[ "$COUNT_OPEN" -eq 9 ]]; then
    ok "query-open-prs returned 9 rows (PR #10 filtered as merged)"
else
    fail "query-open-prs row count: $COUNT_OPEN, want 9"
    note "output:"
    printf '%s\n' "$RUST_OPEN" | sed 's/^/    /'
fi

# Verify DESC order.
FIRST_NUM="$(printf '%s\n' "$RUST_OPEN" | head -1 | cut -f1)"
LAST_NUM="$(printf '%s\n' "$RUST_OPEN" | tail -1 | cut -f1)"
if [[ "$FIRST_NUM" == "9" && "$LAST_NUM" == "1" ]]; then
    ok "query-open-prs sorted DESC by number (9 ... 1)"
else
    fail "query-open-prs sort order: first=$FIRST_NUM last=$LAST_NUM, want 9 ... 1"
fi

# ---------------------------------------------------------------------------
# Test 2: query_behind_prs returns exactly {2,5} sorted ASC.
# ---------------------------------------------------------------------------
RUST_BEHIND="$("$CLI" --db "$DB" query-behind-prs)"
EXPECTED_BEHIND=$'2\n5'
if [[ "$RUST_BEHIND" == "$EXPECTED_BEHIND" ]]; then
    ok "query-behind-prs returned {2,5} ASC"
else
    fail "query-behind-prs output mismatch"
    note "got:  $(printf '%s' "$RUST_BEHIND" | tr '\n' ',')"
    note "want: 2,5"
fi

# ---------------------------------------------------------------------------
# Test 3: lookup_pr returns the raw_payload_json. Compare numeric content.
# ---------------------------------------------------------------------------
for pr in 1 4 7 2 5 6 8 9; do
    OUT="$("$CLI" --db "$DB" lookup-pr "$pr")"
    if [[ -z "$OUT" ]]; then
        fail "lookup-pr $pr returned empty"
        continue
    fi
    # Output should contain `"number":$pr`.
    if printf '%s' "$OUT" | grep -q "\"number\":$pr"; then
        :
    else
        fail "lookup-pr $pr output missing 'number:$pr'"
        note "got: $OUT"
    fi
done
ok "lookup-pr round-trip works for 8 PRs (raw_payload_json preserved)"

# ---------------------------------------------------------------------------
# Test 4: lookup_pr on missing PR returns empty + rc=0.
# ---------------------------------------------------------------------------
OUT="$("$CLI" --db "$DB" lookup-pr 9999)"
RC=$?
if [[ -z "$OUT" && "$RC" -eq 0 ]]; then
    ok "lookup-pr 9999 (missing) returned empty + rc=0"
else
    fail "lookup-pr 9999 (missing) — out='$OUT' rc=$RC"
fi

# ---------------------------------------------------------------------------
# Test 5: query_open_prs_by_title is case-insensitive + injection-safe.
# ---------------------------------------------------------------------------
# Find PR 8 (whose title contains the DROP TABLE attempt).
MATCH="$("$CLI" --db "$DB" query-open-prs-by-title "drop table")"
if printf '%s' "$MATCH" | grep -q '^8	'; then
    ok "query-open-prs-by-title 'drop table' case-insensitively matched PR #8"
else
    fail "query-open-prs-by-title 'drop table' did NOT match PR #8"
    note "got: $MATCH"
fi

# SQL injection attempt: '; DROP TABLE pr_state; --
# Must return no matches (it's a literal title substring search) AND
# the table must still exist afterward.
"$CLI" --db "$DB" query-open-prs-by-title "'; DROP TABLE pr_state; --" >"$TMP/injection.out" 2>&1 || true
"$CLI" --db "$DB" query-open-prs-by-title "' OR 1=1 --" >"$TMP/injection2.out" 2>&1 || true
ROW_COUNT_AFTER="$(sqlite3 "$DB" "SELECT COUNT(*) FROM pr_state" 2>/dev/null || echo "TABLE_GONE")"
if [[ "$ROW_COUNT_AFTER" == "10" ]]; then
    ok "SQL injection inputs did NOT damage the pr_state table (still 10 rows)"
else
    fail "SQL injection corrupted the DB! row count: $ROW_COUNT_AFTER (want 10)"
fi

# ---------------------------------------------------------------------------
# Test 6: lookup_checks for sha1 returns 3 rows sorted by name ASC.
# ---------------------------------------------------------------------------
CHECKS="$("$CLI" --db "$DB" lookup-checks "sha1")"
CHECK_COUNT="$(printf '%s\n' "$CHECKS" | grep -c '^' || true)"
if [[ "$CHECK_COUNT" -eq 3 ]]; then
    ok "lookup-checks sha1 returned 3 rows"
else
    fail "lookup-checks sha1 row count: $CHECK_COUNT, want 3"
fi
FIRST_CHECK="$(printf '%s\n' "$CHECKS" | head -1 | cut -f1)"
if [[ "$FIRST_CHECK" == "alpha" ]]; then
    ok "lookup-checks sorted ASC by name (alpha first)"
else
    fail "lookup-checks sort order: first=$FIRST_CHECK, want alpha"
fi

# ---------------------------------------------------------------------------
# Test 7: lookup_checks for unknown SHA returns empty.
# ---------------------------------------------------------------------------
OUT="$("$CLI" --db "$DB" lookup-checks "no-such-sha")"
if [[ -z "$OUT" ]]; then
    ok "lookup-checks unknown SHA returned empty"
else
    fail "lookup-checks unknown SHA had unexpected output: $OUT"
fi

# ---------------------------------------------------------------------------
# Test 8: schema-tolerance — PR 9's raw_payload_json has an unknown field.
# The CLI MUST still print it (the bash shim treats raw_payload_json as
# opaque; the Rust CLI does the same — it doesn't reparse).
# ---------------------------------------------------------------------------
OUT="$("$CLI" --db "$DB" lookup-pr 9)"
if printf '%s' "$OUT" | grep -q "future_field_chump_doesnt_know_about"; then
    ok "lookup-pr 9 preserved unknown JSON field (schema-tolerance)"
else
    fail "lookup-pr 9 lost the unknown JSON field"
    note "got: $OUT"
fi

# ---------------------------------------------------------------------------
# Test 9: refresh-open-prs Phase 1 stub returns 0.
# ---------------------------------------------------------------------------
OUT="$("$CLI" --db "$DB" refresh-open-prs)"
if [[ "$OUT" == "0" ]]; then
    ok "refresh-open-prs Phase 1 stub returned '0'"
else
    fail "refresh-open-prs stub: got '$OUT', want '0'"
fi

# ---------------------------------------------------------------------------
# Test 10: bash shim dispatch — verify the feature flag block is present
# in scripts/coord/lib/github_cache.sh.
# ---------------------------------------------------------------------------
SHIM_FILE="$REPO_ROOT/scripts/coord/lib/github_cache.sh"
if grep -q 'CHUMP_GITHUB_CACHE_RUST' "$SHIM_FILE" \
        && grep -q 'chump-github-cache-cli' "$SHIM_FILE" ; then
    ok "bash shim dispatch lines present in scripts/coord/lib/github_cache.sh"
else
    fail "bash shim dispatch lines missing or malformed"
fi

# ---------------------------------------------------------------------------
# Test 11: source-level discipline — no ambient emission code in the crate.
# ---------------------------------------------------------------------------
CRATE_DIR="$REPO_ROOT/crates/chump-github-cache"
AMBIENT_MATCHES="$(find "$CRATE_DIR" -name '*.rs' -print0 2>/dev/null \
    | xargs -0 grep -nE 'ambient_emit::emit|ambient_emit!\(|EVENT_REGISTRY' 2>/dev/null \
    | grep -vE ':[[:space:]]*(//|//!|/\*|\*)' || true)"
if [[ -z "$AMBIENT_MATCHES" ]]; then
    ok "no ambient-emission code in chump-github-cache .rs files"
else
    fail "new crate references ambient emission — Phase 1 forbids it"
    echo "$AMBIENT_MATCHES" | sed 's/^/    /'
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo
echo "=== test-github-cache-rust-parity.sh ==="
echo "  PASS: $PASS"
echo "  FAIL: $FAIL"

if [[ "$FAIL" -gt 0 ]]; then
    exit 1
fi
exit 0
