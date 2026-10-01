#!/usr/bin/env bash
# scripts/ci/test-github-cache-callsite-migration.sh — INFRA-7386 (INFRA-3833 slice)
#
# Smoke test that `chump-github-cache-cli refresh-open-prs` behaves
# correctly across three distinct call-sites (three distinct repository
# cache DBs, standing in for three real repositories).
#
# INFRA-3833 made `refresh-open-prs` a real REST bulk refill (see
# crates/chump-github-cache/src/refill.rs) instead of the old Phase 1
# stub that always printed "0". This test deliberately points each
# call-site at a `--repo` that cannot resolve to a real open-PR set
# (`chump-ci-smoke/does-not-exist-<i>`) so the REST call either 404s or
# fails outright in a network-less sandbox — either way the
# graceful-degradation path in refill.rs fires ("any failure returns
# Ok(0), not an error"). That keeps this test deterministic and
# network-independent while still exercising the real CLI argv path
# end-to-end:
#
#   1. Invoking `refresh-open-prs --db <call-site-db> --repo <bogus>`
#      against three independent, pre-seeded call-site DBs (one per
#      repository) exits 0 for each (graceful-degradation contract).
#   2. Each call-site DB still contains its repository's PR entries
#      after the run (the refresh is non-destructive when the REST call
#      cannot succeed).
#
# A real (non-bogus) `--repo` + valid `gh` auth exercises the actual
# refill path — that's a manual-verification concern, not this CI smoke
# test, since CI runners don't carry live GitHub credentials scoped to
# arbitrary target repos.

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
echo "[test] building chump-github-cache-cli..."
BUILD_LOG="$TMP/build.log"
if ! (cd "$REPO_ROOT" && PATH="$HOME/.cargo/bin:$PATH" \
        cargo build --quiet -p chump-github-cache --bin chump-github-cache-cli) \
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
# Seed three independent call-site DBs, one per (synthetic) repository.
# ---------------------------------------------------------------------------
make_call_site_db() {
    local db="$1" repo="$2" pr_count="$3"
    sqlite3 "$db" <<'SQL'
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
    local i
    for ((i = 1; i <= pr_count; i++)); do
        sqlite3 "$db" "INSERT INTO pr_state(number, head_ref, head_sha, base_ref, mergeable_state, auto_merge_enabled, updated_at_api, fetched_at_local, title, raw_payload_json) VALUES ($i, 'feature/$i', 'sha$i', 'main', 'clean', 0, '2026-09-18T19:00:00Z', '2026-09-18T19:01:00Z', '$repo PR $i', '{\"number\":$i,\"repo\":\"$repo\"}');"
    done
}

declare -a REPOS=("chump-ci-smoke/does-not-exist-0" "chump-ci-smoke/does-not-exist-1" "chump-ci-smoke/does-not-exist-2")
declare -a DBS=()
declare -a PR_COUNTS=(3 5 2)

for i in 0 1 2; do
    db="$TMP/call-site-$i.db"
    make_call_site_db "$db" "${REPOS[$i]}" "${PR_COUNTS[$i]}"
    DBS+=("$db")
done
ok "seeded 3 call-site DBs for ${REPOS[*]}"

# ---------------------------------------------------------------------------
# Invoke `refresh-open-prs` against each of the three call-sites and
# assert exit 0 + non-destructive row counts.
# ---------------------------------------------------------------------------
ALL_SUCCEEDED=1
for i in 0 1 2; do
    repo="${REPOS[$i]}"
    db="${DBS[$i]}"
    expect_count="${PR_COUNTS[$i]}"

    before_count="$(sqlite3 "$db" "SELECT COUNT(*) FROM pr_state;")"

    if OUT="$("$CLI" --db "$db" refresh-open-prs --repo "$repo" 2>"$TMP/stderr-$i.log")"; then
        rc=0
    else
        rc=$?
    fi

    if [[ "$rc" -eq 0 ]]; then
        ok "refresh-open-prs exited 0 for call-site $repo"
    else
        fail "refresh-open-prs exited $rc for call-site $repo"
        note "stderr: $(cat "$TMP/stderr-$i.log")"
        ALL_SUCCEEDED=0
    fi

    after_count="$(sqlite3 "$db" "SELECT COUNT(*) FROM pr_state;")"
    if [[ "$after_count" -eq "$before_count" && "$after_count" -eq "$expect_count" ]]; then
        ok "call-site $repo cache DB retained $after_count entries after refresh"
    else
        fail "call-site $repo row count drifted: before=$before_count after=$after_count want=$expect_count"
        ALL_SUCCEEDED=0
    fi
done

if [[ "$ALL_SUCCEEDED" -eq 1 ]]; then
    ok "all 3 call-sites succeeded (refresh-open-prs exit 0 + entries present)"
else
    fail "at least one call-site failed refresh-open-prs or lost cache entries"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo
echo "=== test-github-cache-callsite-migration.sh ==="
echo "  PASS: $PASS"
echo "  FAIL: $FAIL"

if [[ "$FAIL" -gt 0 ]]; then
    exit 1
fi
exit 0
