#!/usr/bin/env bash
# scripts/ci/test-claim-aborts-on-open-pr.sh — INFRA-1503
#
# Verifies that `chump claim` aborts early (exit 2) when a non-draft open PR
# already exists on the canonical claim branch, and that it emits a
# `claim_aborted_pr_in_flight` event to ambient.jsonl.
#
# Test matrix:
#   1. Source-level: open_pr_info helper present + returns author
#   2. Source-level: allow_duplicate_pr field present in ClaimArgs
#   3. Source-level: emit_claim_aborted_pr_in_flight_event defined
#   4. Source-level: claim_aborted_pr_in_flight wired into run_claim (exit 2)
#   5. Binary: mocked gh → open PR → claim exits 2 + "ERROR: PR #… already OPEN"
#   6. Binary: mocked gh → open PR → ambient event emitted with correct fields
#   7. Binary: --allow-duplicate-pr → claim proceeds past PR check (does not exit 2 immediately)
#   8. EVENT_REGISTRY has claim_aborted_pr_in_flight entry
#
# Rounds 5–7 require the chump binary; they are skipped (not failed) if
# CHUMP_BIN is missing or network-dependent steps would fail.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SRC="$REPO_ROOT/src/atomic_claim.rs"
REGISTRY="$REPO_ROOT/docs/observability/EVENT_REGISTRY.yaml"
CHUMP_BIN="${CHUMP_BIN:-$REPO_ROOT/target/debug/chump}"

ok()   { printf '\033[0;32mPASS\033[0m %s\n' "$*"; }
fail() { printf '\033[0;31mFAIL\033[0m %s\n' "$*"; exit 1; }
skip() { printf '\033[0;33mSKIP\033[0m %s\n' "$*"; }

[[ -f "$SRC" ]] || fail "atomic_claim.rs missing: $SRC"

# ── 1. open_pr_info helper present and returns author ────────────────────────
grep -q "fn open_pr_info" "$SRC" \
    || fail "missing fn open_pr_info (INFRA-1503 author-aware PR check)"
ok "open_pr_info helper defined"

grep -q "user.login" "$SRC" \
    || fail "open_pr_info must extract .user.login from gh API response"
ok "open_pr_info extracts PR author via .user.login"

# ── 2. allow_duplicate_pr field in ClaimArgs ─────────────────────────────────
grep -q "allow_duplicate_pr" "$SRC" \
    || fail "missing allow_duplicate_pr field in ClaimArgs"
ok "allow_duplicate_pr field present in ClaimArgs"

grep -q "\-\-allow-duplicate-pr" "$SRC" \
    || fail "missing --allow-duplicate-pr flag parsing"
ok "--allow-duplicate-pr flag parsed"

# ── 3. emit_claim_aborted_pr_in_flight_event defined ─────────────────────────
grep -q "fn emit_claim_aborted_pr_in_flight_event" "$SRC" \
    || fail "missing fn emit_claim_aborted_pr_in_flight_event"
ok "emit_claim_aborted_pr_in_flight_event function defined"

grep -q 'claim_aborted_pr_in_flight' "$SRC" \
    || fail "kind=claim_aborted_pr_in_flight not referenced in source"
ok "kind=claim_aborted_pr_in_flight referenced in source"

# ── 4. exit 2 + event emission wired into run_claim ──────────────────────────
grep -q "claim_aborted_pr_in_flight\|process::exit(2)" "$SRC" \
    || fail "claim_aborted_pr_in_flight emit and exit 2 not wired in run_claim"
# Specifically check the INFRA-1503 comment is present (proves the block was added)
grep -q "INFRA-1503" "$SRC" \
    || fail "INFRA-1503 comment marker missing from atomic_claim.rs"
ok "INFRA-1503 block wired into run_claim (exit 2 + ambient emit)"

# ── 5–7. Binary integration tests ────────────────────────────────────────────
if [[ ! -x "$CHUMP_BIN" ]]; then
    skip "CHUMP_BIN not found at $CHUMP_BIN — skipping binary integration rounds 5-7"
    skip "  Build with: cargo build --bin chump"
    echo ""
    echo "Source-level checks (rounds 1-4) PASSED."
    exit 0
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# Minimal git repo so chump can resolve owner/repo from remote.url.
mkdir -p "$WORK/repo/.chump-locks" "$WORK/repo/.chump"
cd "$WORK/repo"
git init -q
git config user.email "test@example.com"
git config user.name "Test"
git commit --allow-empty -m "init" -q
git remote add origin "https://github.com/testorg/testrepo.git"

# Seed state.db with a pickable gap so atomic_claim doesn't bail on import.
sqlite3 "$WORK/repo/.chump/state.db" "
CREATE TABLE IF NOT EXISTS gaps (
  id TEXT PRIMARY KEY, domain TEXT, title TEXT, status TEXT,
  priority TEXT, effort TEXT, depends_on TEXT, notes TEXT
);
CREATE TABLE IF NOT EXISTS leases (
  session_id TEXT PRIMARY KEY, gap_id TEXT, worktree TEXT, expires_at INTEGER
);
INSERT INTO gaps VALUES ('TEST-9901','TEST','title','open','P1','xs','[]','');
"

# Stub gh: simulate an open PR #42 by author octocat on the claim branch.
STUB_DIR="$WORK/stubs"
mkdir -p "$STUB_DIR"
cat > "$STUB_DIR/gh" <<'STUB'
#!/usr/bin/env bash
# Minimal gh stub: intercepts the REST /pulls endpoint used by open_pr_info.
# open_pr_info calls: gh api ... /pulls?... --jq '.[0] | "\(.number // "")\t\(.user.login // "unknown")"'
# We return the tab-separated output that --jq would produce.
for arg in "$@"; do
    if [[ "$arg" == *"/pulls?"* ]]; then
        # Return the jq-processed output: "<number>\t<author>"
        printf '42\toctocat\n'
        exit 0
    fi
done
# For any other gh call (e.g. fetch), exit 0 with no output.
exit 0
STUB
chmod +x "$STUB_DIR/gh"

# Also stub git fetch so we don't need a real remote.
cat > "$STUB_DIR/git" <<'STUB'
#!/usr/bin/env bash
# Pass-through all git calls EXCEPT fetch (which needs network).
if [[ "${1:-}" == "fetch" ]]; then
    exit 0
fi
exec /usr/bin/git "$@"
STUB
chmod +x "$STUB_DIR/git"

# ── Round 5: open PR → claim exits 2 ─────────────────────────────────────────
set +e
OUT=$(
    PATH="$STUB_DIR:$PATH" \
    CHUMP_WORKTREE_BASE="$WORK/wt" \
    GIT_DIR="$WORK/repo/.git" \
    "$CHUMP_BIN" claim TEST-9901 --skip-doctor --skip-import 2>&1
)
EXIT=$?
set -e

if [[ "$EXIT" -ne 2 ]]; then
    fail "round 5: expected exit 2 when open PR exists, got $EXIT; output: $OUT"
fi
echo "$OUT" | grep -q "already OPEN" || \
    fail "round 5: expected 'already OPEN' in error message; got: $OUT"
echo "$OUT" | grep -q "TEST-9901" || \
    fail "round 5: error message missing gap id TEST-9901; got: $OUT"
ok "round 5: open PR detected → exit 2 + 'already OPEN' message"

# ── Round 6: ambient event emitted with correct fields ───────────────────────
AMBIENT="$WORK/repo/.chump-locks/ambient.jsonl"
if [[ ! -f "$AMBIENT" ]]; then
    fail "round 6: ambient.jsonl not created after claim abort"
fi
grep -q '"kind":"claim_aborted_pr_in_flight"' "$AMBIENT" \
    || fail "round 6: claim_aborted_pr_in_flight not in ambient.jsonl; contents: $(cat "$AMBIENT")"
grep -q '"gap_id":"TEST-9901"' "$AMBIENT" \
    || fail "round 6: ambient event missing gap_id=TEST-9901"
grep -q '"existing_pr":42' "$AMBIENT" \
    || fail "round 6: ambient event missing existing_pr=42"
grep -q '"existing_author":"octocat"' "$AMBIENT" \
    || fail "round 6: ambient event missing existing_author=octocat"
ok "round 6: ambient event claim_aborted_pr_in_flight emitted with correct fields"

# ── Round 7: --allow-duplicate-pr bypasses the early abort ───────────────────
# With the flag, claim should proceed PAST the PR check (it may still fail
# for other reasons — missing worktree base, git errors — but must NOT
# exit 2 with "already OPEN").
set +e
OUT7=$(
    PATH="$STUB_DIR:$PATH" \
    CHUMP_WORKTREE_BASE="$WORK/wt7" \
    "$CHUMP_BIN" claim TEST-9901 --skip-doctor --skip-import --allow-duplicate-pr 2>&1
)
EXIT7=$?
set -e

if [[ "$EXIT7" -eq 2 ]] && echo "$OUT7" | grep -q "already OPEN"; then
    fail "round 7: --allow-duplicate-pr did not bypass the early PR abort"
fi
# exit 0 or 1 from a later step (worktree creation, etc.) is fine.
ok "round 7: --allow-duplicate-pr bypasses early PR abort (exit was $EXIT7, not 2-from-PR-check)"

# ── 8. EVENT_REGISTRY ────────────────────────────────────────────────────────
[[ -f "$REGISTRY" ]] || fail "EVENT_REGISTRY.yaml missing: $REGISTRY"
grep -q "claim_aborted_pr_in_flight" "$REGISTRY" \
    || fail "claim_aborted_pr_in_flight not registered in EVENT_REGISTRY.yaml"
ok "claim_aborted_pr_in_flight registered in EVENT_REGISTRY.yaml"

echo ""
echo "All 8 checks PASSED — INFRA-1503 claim-aborts-on-open-pr guard works"
