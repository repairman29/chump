#!/usr/bin/env bash
# INFRA-2384: integration test for artifact-provenance backfill.
#
# Synthesizes a 3-PR / 6-artifact git repo, runs `chump inventory rebuild`
# against it, and verifies:
#   - all 6 artifact_index rows have introducing_pr populated
#   - activation_state recomputed
#   - `chump inventory show <path>` includes introducing PR + activation
#   - `chump inventory pr <N>` lists the 2 artifacts shipped by that PR
#
# Test isolates via CHUMP_REPO_ROOT, CHUMP_INVENTORY_DB,
# CHUMP_AMBIENT_LOG, CHUMP_INVENTORY_MIGRATION, CHUMP_INVENTORY_REPO,
# GH_TOKEN="" (force CLI path; we'll stub fetch_prs_via_gh_cli by NOT
# providing gh and instead pre-populating pr_index via SQL).
#
# Exit codes:
#   0  all assertions pass
#   1  any assertion fails

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

CHUMP_BIN="${CHUMP_BIN:-$REPO_ROOT/target/debug/chump}"
if [[ ! -x "$CHUMP_BIN" ]]; then
    echo "[test-inventory-provenance-backfill] building chump binary..."
    (cd "$REPO_ROOT" && cargo build -p chump --quiet) || {
        echo "FAIL: cargo build failed"
        exit 1
    }
fi
if [[ ! -x "$CHUMP_BIN" ]]; then
    echo "FAIL: chump binary not found at $CHUMP_BIN after build"
    exit 1
fi

TMP="$(mktemp -d -t chump-inv-prov-XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

cd "$TMP"

echo "[test] tempdir: $TMP"

# ─── synthesize git repo with 3 merge commits, 6 artifacts ──────────────────
git init -q -b main .
git config user.email "test@chump.local"
git config user.name "Test Robot"

# Seed commit so refs exist.
echo "# fixture" > README.md
git add README.md
git commit -q -m "seed: fixture"

# PR 1 (merged 2026-01-10): adds scripts/foo.sh + src/foo.rs
git checkout -q -b feature/pr1
mkdir -p scripts src
echo "echo foo" > scripts/foo.sh
echo "pub fn foo() {}" > src/foo.rs
git add scripts/foo.sh src/foo.rs
GIT_AUTHOR_DATE="2026-01-10T12:00:00Z" GIT_COMMITTER_DATE="2026-01-10T12:00:00Z" \
    git commit -q -m "feat(INFRA-1001): add foo subsystem"
git checkout -q main
GIT_AUTHOR_DATE="2026-01-10T12:05:00Z" GIT_COMMITTER_DATE="2026-01-10T12:05:00Z" \
    git merge -q --no-ff feature/pr1 -m "Merge PR #101 INFRA-1001 add foo"

# PR 2 (merged 2026-02-15): adds scripts/bar.sh + src/bar.rs
git checkout -q -b feature/pr2
echo "echo bar" > scripts/bar.sh
echo "pub fn bar() {}" > src/bar.rs
git add scripts/bar.sh src/bar.rs
GIT_AUTHOR_DATE="2026-02-15T12:00:00Z" GIT_COMMITTER_DATE="2026-02-15T12:00:00Z" \
    git commit -q -m "feat(META-202): add bar subsystem"
git checkout -q main
GIT_AUTHOR_DATE="2026-02-15T12:05:00Z" GIT_COMMITTER_DATE="2026-02-15T12:05:00Z" \
    git merge -q --no-ff feature/pr2 -m "Merge PR #202 META-202 add bar"

# PR 3 (merged 2026-03-20): adds scripts/baz.sh + src/baz.rs
git checkout -q -b feature/pr3
echo "echo baz" > scripts/baz.sh
echo "pub fn baz() {}" > src/baz.rs
git add scripts/baz.sh src/baz.rs
GIT_AUTHOR_DATE="2026-03-20T12:00:00Z" GIT_COMMITTER_DATE="2026-03-20T12:00:00Z" \
    git commit -q -m "feat(INFRA-1303): add baz subsystem"
git checkout -q main
GIT_AUTHOR_DATE="2026-03-20T12:05:00Z" GIT_COMMITTER_DATE="2026-03-20T12:05:00Z" \
    git merge -q --no-ff feature/pr3 -m "Merge PR #303 INFRA-1303 add baz"

git remote add origin https://github.com/test/inv-prov-fixture.git

# ─── isolate inventory state ────────────────────────────────────────────────
export CHUMP_REPO_ROOT="$TMP"
export CHUMP_INVENTORY_DB="$TMP/.inventory.db"
export CHUMP_AMBIENT_LOG="$TMP/.ambient.jsonl"
export CHUMP_INVENTORY_MIGRATION="$REPO_ROOT/migrations/inventory_v1.sql"
export CHUMP_INVENTORY_REPO="test/inv-prov-fixture"
# Skip gh entirely; we'll pre-populate pr_index via SQL.
export GH_TOKEN=""
export GITHUB_TOKEN=""
export PATH="/no-gh:$PATH"

mkdir -p "$TMP/.chump-locks"

# Run rebuild — collect_artifacts will populate artifact_index.
# Note: pr_index will be empty because gh auth missing, but we want to test
# the backfill on a manually populated pr_index. So we run rebuild once to
# index artifacts, then inject PR rows, then run rebuild again.
echo "[test] first rebuild (indexes artifacts, pr_index empty)..."
"$CHUMP_BIN" inventory rebuild > "$TMP/rebuild1.log" 2>&1 || {
    echo "FAIL: first rebuild errored unexpectedly"
    cat "$TMP/rebuild1.log"
    exit 1
}

# ─── inject pr_index rows directly via sqlite ───────────────────────────────
sqlite3 "$CHUMP_INVENTORY_DB" <<SQL
INSERT INTO pr_index (pr_number, title, state, head_ref, base_ref, author,
                      created_at, closed_at, merged_at, gap_id, domain,
                      files_changed, additions, deletions, last_synced_at)
VALUES
  (101, 'feat(INFRA-1001): add foo subsystem', 'MERGED', 'feature/pr1', 'main', 'robot',
   1768089600, 1768089900, 1768089900, 'INFRA-1001', 'INFRA', 2, 2, 0, 1768089900),
  (202, 'feat(META-202): add bar subsystem', 'MERGED', 'feature/pr2', 'main', 'robot',
   1771113600, 1771113900, 1771113900, 'META-202', 'META', 2, 2, 0, 1771113900),
  (303, 'feat(INFRA-1303): add baz subsystem', 'MERGED', 'feature/pr3', 'main', 'robot',
   1773792000, 1773792300, 1773792300, 'INFRA-1303', 'INFRA', 2, 2, 0, 1773792300);
SQL

PR_COUNT=$(sqlite3 "$CHUMP_INVENTORY_DB" "SELECT COUNT(*) FROM pr_index")
if [[ "$PR_COUNT" != "3" ]]; then
    echo "FAIL: expected 3 PRs in pr_index, got $PR_COUNT"
    exit 1
fi

# Reset all artifact introducing_pr to NULL so backfill has work to do.
sqlite3 "$CHUMP_INVENTORY_DB" "UPDATE artifact_index SET introducing_pr=NULL, introducing_gap=NULL"

# Run the backfill via the dedicated CLI path. Since collect_prs requires
# gh auth (which is missing), we call rebuild with a side-channel: we
# can't easily invoke just-backfill from CLI, so we use a tiny rust shim
# via cargo's run with a custom main? Simpler: prepend a fake gh.
mkdir -p "$TMP/fake-gh"
cat > "$TMP/fake-gh/gh" <<'GH'
#!/usr/bin/env bash
# Stub gh that mimics `gh auth token` and `gh pr list` to satisfy
# collect_prs_v2 — emits the 3 PRs already in pr_index.
if [[ "${1:-}" == "auth" && "${2:-}" == "token" ]]; then
    echo "ghp_fake_test_token"
    exit 0
fi
if [[ "${1:-}" == "pr" && "${2:-}" == "list" ]]; then
    cat <<'JSON'
[
  {"number":101,"title":"feat(INFRA-1001): add foo subsystem","state":"MERGED",
   "headRefName":"feature/pr1","baseRefName":"main",
   "author":{"login":"robot"},"createdAt":"2026-01-10T12:00:00Z",
   "closedAt":"2026-01-10T12:05:00Z","mergedAt":"2026-01-10T12:05:00Z",
   "additions":2,"deletions":0,"changedFiles":2},
  {"number":202,"title":"feat(META-202): add bar subsystem","state":"MERGED",
   "headRefName":"feature/pr2","baseRefName":"main",
   "author":{"login":"robot"},"createdAt":"2026-02-15T12:00:00Z",
   "closedAt":"2026-02-15T12:05:00Z","mergedAt":"2026-02-15T12:05:00Z",
   "additions":2,"deletions":0,"changedFiles":2},
  {"number":303,"title":"feat(INFRA-1303): add baz subsystem","state":"MERGED",
   "headRefName":"feature/pr3","baseRefName":"main",
   "author":{"login":"robot"},"createdAt":"2026-03-20T12:00:00Z",
   "closedAt":"2026-03-20T12:05:00Z","mergedAt":"2026-03-20T12:05:00Z",
   "additions":2,"deletions":0,"changedFiles":2}
]
JSON
    exit 0
fi
echo "fake-gh: unknown invocation $*" >&2
exit 1
GH
chmod +x "$TMP/fake-gh/gh"
export PATH="$TMP/fake-gh:$PATH"

echo "[test] second rebuild (with fake gh providing pr_index)..."
"$CHUMP_BIN" inventory rebuild > "$TMP/rebuild2.log" 2>&1
RC=$?
if [[ "$RC" != "0" ]]; then
    echo "FAIL: second rebuild errored (rc=$RC)"
    cat "$TMP/rebuild2.log"
    exit 1
fi

# ─── assertion 1: every shell + rust artifact has introducing_pr set ────────
MISSING=$(sqlite3 "$CHUMP_INVENTORY_DB" \
    "SELECT COUNT(*) FROM artifact_index
     WHERE introducing_pr IS NULL
       AND class IN ('shell-script','rust-mod')")
if [[ "$MISSING" != "0" ]]; then
    echo "FAIL: $MISSING shell/rust artifacts have introducing_pr=NULL"
    sqlite3 "$CHUMP_INVENTORY_DB" \
        "SELECT path, class FROM artifact_index
         WHERE introducing_pr IS NULL AND class IN ('shell-script','rust-mod')"
    exit 1
fi
echo "[test] OK: all 6 shell/rust artifacts have introducing_pr populated"

# ─── assertion 2: foo.sh → PR 101 (INFRA-1001) ─────────────────────────────
FOO_PR=$(sqlite3 "$CHUMP_INVENTORY_DB" \
    "SELECT introducing_pr FROM artifact_index WHERE path='scripts/foo.sh'")
FOO_GAP=$(sqlite3 "$CHUMP_INVENTORY_DB" \
    "SELECT introducing_gap FROM artifact_index WHERE path='scripts/foo.sh'")
if [[ "$FOO_PR" != "101" || "$FOO_GAP" != "INFRA-1001" ]]; then
    echo "FAIL: scripts/foo.sh expected (101, INFRA-1001), got ($FOO_PR, $FOO_GAP)"
    exit 1
fi
echo "[test] OK: scripts/foo.sh → PR 101 (INFRA-1001)"

# ─── assertion 3: bar.rs → PR 202 (META-202) ───────────────────────────────
BAR_PR=$(sqlite3 "$CHUMP_INVENTORY_DB" \
    "SELECT introducing_pr FROM artifact_index WHERE path='src/bar.rs'")
BAR_GAP=$(sqlite3 "$CHUMP_INVENTORY_DB" \
    "SELECT introducing_gap FROM artifact_index WHERE path='src/bar.rs'")
if [[ "$BAR_PR" != "202" || "$BAR_GAP" != "META-202" ]]; then
    echo "FAIL: src/bar.rs expected (202, META-202), got ($BAR_PR, $BAR_GAP)"
    exit 1
fi
echo "[test] OK: src/bar.rs → PR 202 (META-202)"

# ─── assertion 4: baz.sh → PR 303 (INFRA-1303) ─────────────────────────────
BAZ_PR=$(sqlite3 "$CHUMP_INVENTORY_DB" \
    "SELECT introducing_pr FROM artifact_index WHERE path='scripts/baz.sh'")
BAZ_GAP=$(sqlite3 "$CHUMP_INVENTORY_DB" \
    "SELECT introducing_gap FROM artifact_index WHERE path='scripts/baz.sh'")
if [[ "$BAZ_PR" != "303" || "$BAZ_GAP" != "INFRA-1303" ]]; then
    echo "FAIL: scripts/baz.sh expected (303, INFRA-1303), got ($BAZ_PR, $BAZ_GAP)"
    exit 1
fi
echo "[test] OK: scripts/baz.sh → PR 303 (INFRA-1303)"

# ─── assertion 5: activation_state was recomputed ──────────────────────────
UNKNOWN=$(sqlite3 "$CHUMP_INVENTORY_DB" \
    "SELECT COUNT(*) FROM artifact_index
     WHERE activation_state='unknown' AND introducing_pr IS NOT NULL")
if [[ "$UNKNOWN" != "0" ]]; then
    echo "FAIL: $UNKNOWN artifacts still 'unknown' despite having introducing_pr"
    exit 1
fi
echo "[test] OK: activation_state recomputed for backfilled artifacts"

# ─── assertion 6: chump inventory show <path> emits the rich profile ───────
SHOW_OUT=$("$CHUMP_BIN" inventory show scripts/foo.sh 2>&1)
if ! echo "$SHOW_OUT" | grep -q "PR #101"; then
    echo "FAIL: chump inventory show scripts/foo.sh did not mention PR #101"
    echo "$SHOW_OUT"
    exit 1
fi
if ! echo "$SHOW_OUT" | grep -q "INFRA-1001"; then
    echo "FAIL: chump inventory show scripts/foo.sh did not mention INFRA-1001"
    echo "$SHOW_OUT"
    exit 1
fi
echo "[test] OK: chump inventory show scripts/foo.sh includes PR + gap"

# ─── assertion 7: chump inventory show --json structured ───────────────────
SHOW_JSON=$("$CHUMP_BIN" inventory show scripts/foo.sh --json 2>&1)
if ! echo "$SHOW_JSON" | grep -q '"introducing_pr": 101'; then
    echo "FAIL: chump inventory show --json did not include introducing_pr=101"
    echo "$SHOW_JSON"
    exit 1
fi
echo "[test] OK: chump inventory show --json emits structured introducing_pr"

# ─── assertion 8: chump inventory pr <N> lists artifacts ───────────────────
PR_OUT=$("$CHUMP_BIN" inventory pr 101 2>&1)
if ! echo "$PR_OUT" | grep -q "scripts/foo.sh"; then
    echo "FAIL: chump inventory pr 101 did not list scripts/foo.sh"
    echo "$PR_OUT"
    exit 1
fi
if ! echo "$PR_OUT" | grep -q "src/foo.rs"; then
    echo "FAIL: chump inventory pr 101 did not list src/foo.rs"
    echo "$PR_OUT"
    exit 1
fi
echo "[test] OK: chump inventory pr 101 lists both shipped artifacts"

# ─── assertion 9: chump inventory pr <N> --json ────────────────────────────
PR_JSON=$("$CHUMP_BIN" inventory pr 202 --json 2>&1)
if ! echo "$PR_JSON" | grep -q '"pr_number": 202'; then
    echo "FAIL: chump inventory pr 202 --json missing pr_number"
    echo "$PR_JSON"
    exit 1
fi
if ! echo "$PR_JSON" | grep -q '"gap_id": "META-202"'; then
    echo "FAIL: chump inventory pr 202 --json missing META-202"
    echo "$PR_JSON"
    exit 1
fi
echo "[test] OK: chump inventory pr 202 --json is well-formed"

echo
echo "[test-inventory-provenance-backfill] all 9 assertions passed"
exit 0
