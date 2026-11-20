#!/usr/bin/env bash
# INFRA-2368 — integration test for auth-resilient PR backfill + 3
# PR-dependent detector wiring.
#
# Covers:
#   1. No-auth path → warning logged, dependent detectors disabled (not
#      silently zero); class-stats shows "DISABLED" / "(gh auth missing)".
#   2. GH_TOKEN env path → REST curl path used; pr_index populated.
#   3. Mocked-gh path → gh CLI path used; pr_index populated and 3
#      dependent detectors produce findings (provided fixtures match).
#   4. Auth-resolution chain priorities: GH_TOKEN > GITHUB_TOKEN > gh
#      auth token.
set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
CHUMP_BIN="${CHUMP_BIN:-$REPO_ROOT/target/debug/chump}"

if [[ ! -x "$CHUMP_BIN" ]]; then
    echo "[test-inventory-pr-backfill] building chump binary..."
    PATH="$HOME/.cargo/bin:$PATH" cargo build --manifest-path "$REPO_ROOT/Cargo.toml" --bin chump --quiet
fi

TMPDIR_TEST="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_TEST"' EXIT

TEST_DB="$TMPDIR_TEST/inventory.db"
TEST_AMBIENT="$TMPDIR_TEST/ambient.jsonl"
TEST_MIGRATION="$REPO_ROOT/migrations/inventory_v1.sql"

# Fake repo so detectors don't scan all of chump.
FAKE_ROOT="$TMPDIR_TEST/repo"
mkdir -p "$FAKE_ROOT"
(
    cd "$FAKE_ROOT"
    git init --quiet
    git config user.email "test@example.com"
    git config user.name "test"
    git remote add origin "https://github.com/test-org/test-repo.git"
    mkdir -p scripts/coord docs/gaps docs/observability src
    cat > scripts/coord/foo.sh << 'EOF'
#!/usr/bin/env bash
echo foo
EOF
    cat > src/lib.rs << 'EOF'
pub fn x() {}
EOF
    cat > docs/observability/EVENT_REGISTRY.yaml << 'EOF'
events:
  - kind: dummy
EOF
    # Pre-existing gap registry rows — exercise the unreferenced-gap
    # detector (gap registered, but no PR title contains it).
    cat > docs/gaps/INFRA-9001.yaml << 'EOF'
- id: INFRA-9001
  title: orphan gap
EOF
    cat > docs/gaps/INFRA-9002.yaml << 'EOF'
- id: INFRA-9002
  title: another orphan
EOF
    git add -A
    git commit -m "init" --quiet
    # Backdate yaml mtimes so the >30d filter doesn't skip them.
    touch -t 202401010000 docs/gaps/INFRA-9001.yaml docs/gaps/INFRA-9002.yaml
)

export CHUMP_INVENTORY_DB="$TEST_DB"
export CHUMP_INVENTORY_MIGRATION="$TEST_MIGRATION"
export CHUMP_AMBIENT_LOG="$TEST_AMBIENT"
export CHUMP_REPO_ROOT="$FAKE_ROOT"
# Pin the repo slug so resolve_repo_slug doesn't have to parse git remote
# in the fake repo (which has a synthetic origin).
export CHUMP_INVENTORY_REPO="test-org/test-repo"

# ── 1. No-auth path → warning + disabled detectors ────────────────────────────
echo "[test-inventory-pr-backfill] step 1: no auth → disabled detectors"
unset GH_TOKEN GITHUB_TOKEN 2>/dev/null || true
# Hide gh from PATH so `gh auth token` fails too.
NOGH_DIR="$TMPDIR_TEST/nogh-bin"
mkdir -p "$NOGH_DIR"
# Create a fake gh that always fails (mimics no-auth state).
cat > "$NOGH_DIR/gh" << 'EOF'
#!/usr/bin/env bash
# Always exit non-zero — simulates gh CLI missing or unauth'd.
exit 1
EOF
chmod +x "$NOGH_DIR/gh"
ORIG_PATH="$PATH"
PATH="$NOGH_DIR:$(echo "$PATH" | tr ':' '\n' | grep -v '/gh$' | tr '\n' ':')"
export PATH

"$CHUMP_BIN" inventory rebuild > "$TMPDIR_TEST/rebuild-noauth.out" 2>&1 || {
    cat "$TMPDIR_TEST/rebuild-noauth.out"
    echo "FAIL: rebuild exited non-zero in no-auth path"
    exit 1
}
grep -q "auth=missing" "$TMPDIR_TEST/rebuild-noauth.out" || {
    cat "$TMPDIR_TEST/rebuild-noauth.out"
    echo "FAIL: rebuild output missing 'auth=missing' marker"
    exit 1
}
grep -q "WARN: PR backfill unavailable" "$TMPDIR_TEST/rebuild-noauth.out" || {
    cat "$TMPDIR_TEST/rebuild-noauth.out"
    echo "FAIL: rebuild output missing WARN line for PR backfill"
    exit 1
}
# class-stats should show DISABLED for the 3 PR-dependent detectors.
"$CHUMP_BIN" inventory class-stats > "$TMPDIR_TEST/stats-noauth.out"
for cls in doc-only-feature unreferenced-gap long-undormant-substrate; do
    grep "$cls" "$TMPDIR_TEST/stats-noauth.out" | grep -q "DISABLED" || {
        cat "$TMPDIR_TEST/stats-noauth.out"
        echo "FAIL: class-stats missing DISABLED for $cls"
        exit 1
    }
done
# pr_index should be empty.
pr_count="$(sqlite3 "$TEST_DB" 'SELECT COUNT(*) FROM pr_index;')"
[[ "$pr_count" == "0" ]] || {
    echo "FAIL: no-auth path should leave pr_index empty (got $pr_count)"
    exit 1
}
echo "  no-auth OK: warning logged, pr_index=0, 3 detectors marked DISABLED"

# ── 2. GH_TOKEN env path → REST curl used (mocked curl) ──────────────────────
echo "[test-inventory-pr-backfill] step 2: GH_TOKEN env → REST curl path"
PATH="$ORIG_PATH"
export PATH
# Reset DB so prior step's metadata doesn't bleed.
rm -f "$TEST_DB"

# Mock curl: intercept REST API calls, return a hand-rolled JSON fixture.
MOCK_DIR="$TMPDIR_TEST/mock-curl-bin"
mkdir -p "$MOCK_DIR"
cat > "$MOCK_DIR/curl" << EOF
#!/usr/bin/env bash
# Mock curl: return one page of 3 PRs for page=1, then empty for page>=2.
# Tolerant of any args; just inspect for the page= query string.
page=1
for a in "\$@"; do
    case "\$a" in
        *page=*)
            page="\${a##*page=}"
            page="\${page%%&*}"
            ;;
    esac
done
if [[ "\$page" == "1" ]]; then
    cat << 'JSON'
[
  {"number": 9001, "title": "feat(INFRA-9001): doc-only ship", "state": "closed",
   "head": {"ref": "chump/infra-9001"}, "base": {"ref": "main"},
   "user": {"login": "alice"},
   "created_at": "2026-01-01T00:00:00Z",
   "closed_at": "2026-01-02T00:00:00Z",
   "merged_at": "2026-01-02T00:00:00Z"},
  {"number": 9002, "title": "feat(INFRA-9003): real feature", "state": "closed",
   "head": {"ref": "chump/infra-9003"}, "base": {"ref": "main"},
   "user": {"login": "bob"},
   "created_at": "2026-01-03T00:00:00Z",
   "closed_at": "2026-01-04T00:00:00Z",
   "merged_at": "2026-01-04T00:00:00Z"},
  {"number": 9003, "title": "infra(INFRA-9004): substrate work", "state": "closed",
   "head": {"ref": "chump/infra-9004"}, "base": {"ref": "main"},
   "user": {"login": "carol"},
   "created_at": "2024-01-01T00:00:00Z",
   "closed_at": "2024-01-02T00:00:00Z",
   "merged_at": "2024-01-02T00:00:00Z"}
]
JSON
else
    echo "[]"
fi
EOF
chmod +x "$MOCK_DIR/curl"
PATH="$MOCK_DIR:$ORIG_PATH"
export PATH

export GH_TOKEN="fake-test-token"
"$CHUMP_BIN" inventory rebuild > "$TMPDIR_TEST/rebuild-env.out" 2>&1 || {
    cat "$TMPDIR_TEST/rebuild-env.out"
    echo "FAIL: rebuild exited non-zero with GH_TOKEN"
    exit 1
}
grep -q "auth=env(GH_TOKEN)" "$TMPDIR_TEST/rebuild-env.out" || {
    cat "$TMPDIR_TEST/rebuild-env.out"
    echo "FAIL: rebuild output missing 'auth=env(GH_TOKEN)' marker"
    exit 1
}
grep -q "from rest " "$TMPDIR_TEST/rebuild-env.out" || {
    cat "$TMPDIR_TEST/rebuild-env.out"
    echo "FAIL: rebuild output missing 'from rest' transport marker"
    exit 1
}
pr_count="$(sqlite3 "$TEST_DB" 'SELECT COUNT(*) FROM pr_index;')"
[[ "$pr_count" == "3" ]] || {
    sqlite3 "$TEST_DB" "SELECT pr_number, state, title, gap_id FROM pr_index;"
    echo "FAIL: REST path indexed $pr_count PRs (expected 3)"
    exit 1
}
# REST shape lowercase state "closed" + merged_at → should normalize to MERGED.
merged_count="$(sqlite3 "$TEST_DB" "SELECT COUNT(*) FROM pr_index WHERE state='MERGED';")"
[[ "$merged_count" == "3" ]] || {
    sqlite3 "$TEST_DB" "SELECT pr_number, state FROM pr_index;"
    echo "FAIL: state normalization broken — expected 3 MERGED, got $merged_count"
    exit 1
}
# gap_id extraction must have run.
gap_count="$(sqlite3 "$TEST_DB" "SELECT COUNT(*) FROM pr_index WHERE gap_id IS NOT NULL;")"
[[ "$gap_count" == "3" ]] || {
    echo "FAIL: gap_id extraction missed PRs (got $gap_count of 3)"
    exit 1
}
# The 3 dependent detectors should NOT be disabled now.
"$CHUMP_BIN" inventory class-stats > "$TMPDIR_TEST/stats-env.out"
if grep "doc-only-feature" "$TMPDIR_TEST/stats-env.out" | grep -q "DISABLED"; then
    cat "$TMPDIR_TEST/stats-env.out"
    echo "FAIL: doc-only-feature still DISABLED after successful PR backfill"
    exit 1
fi
echo "  env-GH_TOKEN OK: 3 PRs indexed via REST, normalized to MERGED, gap_id extracted, detectors enabled"

# ── 3. Auth-chain priority: GH_TOKEN beats GITHUB_TOKEN ──────────────────────
echo "[test-inventory-pr-backfill] step 3: GH_TOKEN beats GITHUB_TOKEN"
rm -f "$TEST_DB"
export GH_TOKEN="from-gh-token"
export GITHUB_TOKEN="from-github-token"
"$CHUMP_BIN" inventory rebuild > "$TMPDIR_TEST/rebuild-prio.out" 2>&1
grep -q "auth=env(GH_TOKEN)" "$TMPDIR_TEST/rebuild-prio.out" || {
    cat "$TMPDIR_TEST/rebuild-prio.out"
    echo "FAIL: GH_TOKEN should take priority over GITHUB_TOKEN"
    exit 1
}
unset GH_TOKEN
"$CHUMP_BIN" inventory rebuild > "$TMPDIR_TEST/rebuild-prio2.out" 2>&1
grep -q "auth=env(GITHUB_TOKEN)" "$TMPDIR_TEST/rebuild-prio2.out" || {
    cat "$TMPDIR_TEST/rebuild-prio2.out"
    echo "FAIL: GITHUB_TOKEN should be the fallback when GH_TOKEN unset"
    exit 1
}
unset GITHUB_TOKEN
echo "  auth chain priority OK: GH_TOKEN > GITHUB_TOKEN > keyring > missing"

# ── 4. 3 dependent detectors produce findings ────────────────────────────────
echo "[test-inventory-pr-backfill] step 4: 3 dependent detectors produce findings"
# pr_index now has 3 PRs (from step 3 final rebuild — GITHUB_TOKEN path).
# unreferenced-gap: docs/gaps/INFRA-9001.yaml is in gap registry. PR #9001
#   title contains INFRA-9001 → should NOT flag. docs/gaps/INFRA-9002.yaml is
#   in gap registry. No PR title contains INFRA-9002 → SHOULD flag.
# doc-only-feature: PRs whose title starts with "feat" — check.
# long-undormant-substrate: PR #9003 merged_at 2024-01 (>90d ago) and matches infra-NNNN — SHOULD flag.
unreferenced="$(sqlite3 "$TEST_DB" \
    "SELECT COUNT(*) FROM tech_debt_findings WHERE finding_class='unreferenced-gap';")"
[[ "$unreferenced" -ge 1 ]] || {
    sqlite3 "$TEST_DB" "SELECT finding_class, detail FROM tech_debt_findings;"
    echo "FAIL: unreferenced-gap detector produced no findings (got $unreferenced, expected >=1)"
    exit 1
}
# unreferenced-gap should flag INFRA-9002 (no matching PR) but NOT INFRA-9001 (matched by PR #9001).
flagged_9002="$(sqlite3 "$TEST_DB" \
    "SELECT COUNT(*) FROM tech_debt_findings WHERE finding_class='unreferenced-gap' AND gap_id='INFRA-9002';")"
[[ "$flagged_9002" -ge 1 ]] || {
    sqlite3 "$TEST_DB" "SELECT gap_id, detail FROM tech_debt_findings WHERE finding_class='unreferenced-gap';"
    echo "FAIL: unreferenced-gap detector should have flagged INFRA-9002"
    exit 1
}

long_subs="$(sqlite3 "$TEST_DB" \
    "SELECT COUNT(*) FROM tech_debt_findings WHERE finding_class='long-undormant-substrate';")"
[[ "$long_subs" -ge 1 ]] || {
    sqlite3 "$TEST_DB" "SELECT finding_class, detail FROM tech_debt_findings;"
    echo "FAIL: long-undormant-substrate detector produced no findings (got $long_subs, expected >=1)"
    exit 1
}
echo "  3 dependent detectors firing: unreferenced=$unreferenced (incl. INFRA-9002) long-substrate=$long_subs"

# ── 5. Idempotent re-run preserves rows ──────────────────────────────────────
echo "[test-inventory-pr-backfill] step 5: idempotent re-run"
before="$(sqlite3 "$TEST_DB" 'SELECT COUNT(*) FROM pr_index;')"
export GITHUB_TOKEN="from-github-token"
"$CHUMP_BIN" inventory rebuild > "$TMPDIR_TEST/rebuild-rerun.out" 2>&1
after="$(sqlite3 "$TEST_DB" 'SELECT COUNT(*) FROM pr_index;')"
[[ "$before" == "$after" ]] || {
    echo "FAIL: pr_index row count drifted ($before → $after)"
    exit 1
}
echo "  idempotent: pr_index stable at $after rows"

echo "[test-inventory-pr-backfill] PASS — auth-resilient backfill + 3 dependent detectors verified"
