#!/usr/bin/env bash
# capability-guard-exempt: builds chump in-test via cargo; not subject to runner binary cache lag (CREDIBLE-077)
# scripts/ci/test-claim-path-overlap.sh — INFRA-3798
#
# Verifies the claim-time path overlap check (file-level): `chump claim
# --paths <csv>` is refused when a declared path already appears in the
# changed-file list of an open PR, and proceeds normally when it doesn't.
#
# Mocks the `gh` CLI via a PATH shim so the test runs offline/unauthenticated
# and deterministically returns a mock open PR with a fixed file list
# (mirrors the approach in scripts/ci/test-claim-open-pr-abort.sh, INFRA-1503).
#
# Coverage:
#   1. Claim with --paths containing a file that's in the mock open PR's file
#      list is refused (non-zero exit) with the redirect-options message,
#      citing the blocking PR number + gap + overlapping paths.
#   2. kind=claim_path_overlap_blocked is emitted to ambient.jsonl with the
#      required fields.
#   3. Claim with --paths NOT in the mock PR's file list succeeds.
#   4. --allow-overlap bypasses the block (still audit-logged).

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

ok()   { printf '\033[0;32mPASS\033[0m %s\n' "$*"; }
fail() { printf '\033[0;31mFAIL\033[0m %s\n' "$*"; exit 1; }
hdr()  { printf '\n--- %s ---\n' "$*"; }

CHUMP_BIN="$REPO_ROOT/target/debug/chump"
if [[ ! -x "$CHUMP_BIN" ]]; then
    (cd "$REPO_ROOT" && cargo build --bin chump --quiet 2>&1 | tail -20) \
        || fail "cargo build --bin chump failed; cannot run integration"
fi
[[ -x "$CHUMP_BIN" ]] || fail "no debug chump binary at $CHUMP_BIN"

WORK="$(mktemp -d -t chump-3798-XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

FAKE_REPO="$WORK/repo"
mkdir -p "$FAKE_REPO/.chump" "$FAKE_REPO/.chump-locks" "$FAKE_REPO/docs/gaps"

cd "$FAKE_REPO"
git init -q -b main
git config user.email "ci@test.local"
git config user.name "CI Test"
git config commit.gpgsign false
echo "test" > README.md
git add README.md
git commit -q -m "init"
git remote add origin "$FAKE_REPO"
cd "$REPO_ROOT"

seed_gap_db() {
    local db="$FAKE_REPO/.chump/state.db"
    local gap_id="$1"
    sqlite3 "$db" <<SQL
CREATE TABLE IF NOT EXISTS gaps (
    id TEXT PRIMARY KEY,
    domain TEXT,
    title TEXT,
    status TEXT,
    priority TEXT,
    acceptance_criteria TEXT
);
CREATE TABLE IF NOT EXISTS leases (
    session_id TEXT PRIMARY KEY,
    gap_id TEXT,
    worktree TEXT,
    expires_at INTEGER
);
INSERT OR REPLACE INTO gaps(id, domain, title, status, priority, acceptance_criteria)
VALUES('$gap_id', 'INFRA', 'test gap for path overlap', 'open', 'P1', 'n/a');
SQL
}

# PATH shim for `gh`: the only call that matters is
#   gh pr list --state open --limit 80 --json number,title,files
# which must return a single mock open PR (a stand-in for a draft PR) that
# already touches src/overlap_target.rs. Every other invocation (fuzzy-match's
# `--json number,title`, the open-PR-in-flight `gh api ...pulls?state=open`
# probe, nugget prefetch, etc.) returns an empty/successful no-op so this test
# isolates the INFRA-3798 gate.
SHIMDIR="$WORK/bin"
mkdir -p "$SHIMDIR"
cat > "$SHIMDIR/gh" <<'SHIM'
#!/usr/bin/env bash
case " $* " in
    *" files "*|*"number,title,files"*)
        cat <<'JSON'
[{"number":4321,"title":"INFRA-9999: unrelated in-flight change","files":[{"path":"src/overlap_target.rs"}]}]
JSON
        exit 0
        ;;
    *)
        exit 0
        ;;
esac
SHIM
chmod +x "$SHIMDIR/gh"

run_claim() {
    local gap_id="$1"
    shift
    PATH="$SHIMDIR:$PATH" \
    CHUMP_REPO="$FAKE_REPO" \
    CHUMP_WORKTREE_BASE="$WORK/worktrees" \
    CHUMP_REMOTE="origin" \
    CHUMP_BASE_BRANCH="main" \
    "$CHUMP_BIN" claim "$gap_id" \
        --skip-doctor --skip-import \
        "$@" 2>&1
}

mkdir -p "$WORK/worktrees"
AMBIENT="$FAKE_REPO/.chump-locks/ambient.jsonl"

# ── Check 1: claim blocked when --paths overlaps the mock open PR's files ────
hdr "Check 1: claim refused when --paths overlaps an open PR's file list"

rm -f "$FAKE_REPO/.chump/state.db"
seed_gap_db "INFRA-TEST-OVERLAP"
rm -rf "$WORK/worktrees/chump-infra-test-overlap"

set +e
OUT1=$(run_claim "INFRA-TEST-OVERLAP" --paths "src/overlap_target.rs")
RC1=$?
set -e

(( RC1 != 0 )) || { printf '%s\n' "$OUT1"; fail "expected non-zero exit on path overlap; got rc=0"; }
ok "claim exited non-zero (rc=$RC1) on path overlap"

grep -q "paths overlap with open PR #4321" <<<"$OUT1" \
    || { printf '%s\n' "$OUT1"; fail "diagnostic must mention 'paths overlap with open PR #4321'"; }
grep -q "gap INFRA-9999" <<<"$OUT1" \
    || { printf '%s\n' "$OUT1"; fail "diagnostic must mention blocking gap INFRA-9999"; }
grep -q "src/overlap_target.rs" <<<"$OUT1" \
    || { printf '%s\n' "$OUT1"; fail "diagnostic must list the overlapping path"; }
grep -q -- "--allow-overlap" <<<"$OUT1" \
    || { printf '%s\n' "$OUT1"; fail "diagnostic must mention --allow-overlap escape hatch"; }
ok "diagnostic includes PR number, blocking gap, overlapping paths, and --allow-overlap option"

# ── Check 2: ambient event emitted ───────────────────────────────────────────
hdr "Check 2: kind=claim_path_overlap_blocked emitted to ambient.jsonl"

[[ -f "$AMBIENT" ]] || fail "ambient.jsonl was not created: $AMBIENT"
grep -q '"kind":"claim_path_overlap_blocked"' "$AMBIENT" \
    || { cat "$AMBIENT"; fail "ambient.jsonl missing claim_path_overlap_blocked event"; }
grep -q '"claimed_gap":"INFRA-TEST-OVERLAP"' "$AMBIENT" \
    || { cat "$AMBIENT"; fail "ambient event missing claimed_gap field"; }
grep -q '"blocking_pr":4321' "$AMBIENT" \
    || { cat "$AMBIENT"; fail "ambient event missing blocking_pr field"; }
grep -q '"blocking_gap":"INFRA-9999"' "$AMBIENT" \
    || { cat "$AMBIENT"; fail "ambient event missing blocking_gap field"; }
grep -q '"overlapping_paths":\["src/overlap_target.rs"\]' "$AMBIENT" \
    || { cat "$AMBIENT"; fail "ambient event missing overlapping_paths field"; }
ok "ambient event has claimed_gap, blocking_pr, blocking_gap, overlapping_paths"

# Verify no worktree leaked (gate runs before worktree add).
if [[ -d "$WORK/worktrees/chump-infra-test-overlap" ]]; then
    fail "worktree was created despite the path-overlap block"
fi
ok "no worktree leaked (block fired before worktree create)"

# ── Check 3: claim with a different (non-overlapping) path succeeds ─────────
hdr "Check 3: claim with a non-overlapping --paths is NOT blocked"

rm -f "$FAKE_REPO/.chump/state.db"
seed_gap_db "INFRA-TEST-NO-OVERLAP"
rm -rf "$WORK/worktrees/chump-infra-test-no-overlap"

set +e
OUT3=$(run_claim "INFRA-TEST-NO-OVERLAP" --paths "docs/unrelated-file.md")
RC3=$?
set -e

(( RC3 == 0 )) \
    || { printf '%s\n' "$OUT3"; fail "expected claim with non-overlapping path to succeed; got rc=$RC3"; }
ok "claim with a non-overlapping path succeeded (rc=0)"

grep -qi "paths overlap with open PR" <<<"$OUT3" \
    && { printf '%s\n' "$OUT3"; fail "unexpected overlap message on non-overlapping claim"; }
ok "no overlap message printed for a non-overlapping path"

# ── Check 4: --allow-overlap bypasses the block (still audit-logged) ────────
hdr "Check 4: --allow-overlap bypasses the block"

rm -f "$FAKE_REPO/.chump/state.db"
seed_gap_db "INFRA-TEST-ALLOW-OVERLAP"
rm -rf "$WORK/worktrees/chump-infra-test-allow-overlap"
rm -f "$AMBIENT"

set +e
OUT4=$(run_claim "INFRA-TEST-ALLOW-OVERLAP" --paths "src/overlap_target.rs" --allow-overlap)
RC4=$?
set -e

(( RC4 == 0 )) \
    || { printf '%s\n' "$OUT4"; fail "expected --allow-overlap claim to succeed; got rc=$RC4"; }
ok "claim with --allow-overlap succeeded (rc=0) despite the overlap"

grep -q '"kind":"claim_path_overlap_blocked"' "$AMBIENT" \
    || { cat "$AMBIENT" 2>/dev/null; fail "ambient event must still be emitted (audit-logged) with --allow-overlap"; }
ok "ambient event still emitted with --allow-overlap (audit-logged)"

echo
echo "All INFRA-3798 claim-time path-overlap assertions passed."
