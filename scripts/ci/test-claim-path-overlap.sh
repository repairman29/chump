#!/usr/bin/env bash
# capability-guard-exempt: builds chump in-test via cargo; not subject to runner binary cache lag (CREDIBLE-077)
# scripts/ci/test-claim-path-overlap.sh — INFRA-3798
#
# CI test for the claim-time file-level path overlap check (INFRA-2434 slice).
#
# Verifies:
#   1. Source-level shape: check fn + emitter + --allow-overlap flag present.
#   2. A claim declaring --paths that match a changed file on a mocked open
#      PR is BLOCKED (non-zero exit) with the redirect message and the
#      overlapping PR/gap/paths.
#   3. kind=claim_path_overlap_blocked is emitted to ambient.jsonl.
#   4. A claim declaring --paths with NO overlap is NOT blocked by this gate.
#
# Exits non-zero on any failure.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SRC="$REPO_ROOT/crates/chump-atomic-claim/src/atomic_claim.rs"

PASS=0
FAIL=0
FAILS=()

ok()   { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); FAILS+=("$1"); }

echo "=== INFRA-3798 chump claim path-overlap tests ==="
echo

# ── Round 1: source-level shape ───────────────────────────────────────────
echo "Round 1: source-level shape"

[[ -f "$SRC" ]] || { fail "atomic_claim.rs missing: $SRC"; SRC_MISSING=1; }

if [[ -z "${SRC_MISSING:-}" ]]; then
    grep -q "fn check_claim_path_overlap" "$SRC" \
        && ok "check_claim_path_overlap helper defined" \
        || fail "missing fn check_claim_path_overlap"

    grep -q "fn emit_claim_path_overlap_blocked" "$SRC" \
        && ok "emit_claim_path_overlap_blocked emitter defined" \
        || fail "missing fn emit_claim_path_overlap_blocked"

    grep -qE 'kind\\?":\\?"claim_path_overlap_blocked\\?"' "$SRC" \
        && ok "canonical kind string claim_path_overlap_blocked present" \
        || fail "missing canonical kind string claim_path_overlap_blocked"

    grep -q '"--allow-overlap"' "$SRC" \
        && ok "--allow-overlap flag parsed" \
        || fail "missing --allow-overlap flag parsing"

    grep -q "allow_overlap" "$SRC" \
        && ok "allow_overlap field wired on ClaimArgs" \
        || fail "missing allow_overlap field on ClaimArgs"
fi

# ── Round 2: binary integration (mocked gh) ───────────────────────────────
echo
echo "Round 2: binary integration (mocked gh)"

if [[ -z "${CHUMP_BIN:-}" ]]; then
    CANDIDATE="${CARGO_TARGET_DIR:-$REPO_ROOT/target}/debug/chump"
    if [[ -x "$CANDIDATE" ]]; then
        CHUMP_BIN="$CANDIDATE"
    else
        echo "Building chump binary..."
        (cd "$REPO_ROOT" && cargo build --bin chump -q)
        CHUMP_BIN="${CARGO_TARGET_DIR:-$REPO_ROOT/target}/debug/chump"
    fi
fi
[[ -x "$CHUMP_BIN" ]] || fail "no debug chump binary at $CHUMP_BIN"

WORK="$(mktemp -d -t chump-3798-XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

FAKE_REPO="$WORK/repo"
mkdir -p "$FAKE_REPO/.chump" "$FAKE_REPO/.chump-locks" "$FAKE_REPO/docs/gaps"

(cd "$FAKE_REPO" \
    && git init -q \
    && git config user.email "ci@test.local" \
    && git config user.name "CI Test" \
    && git config commit.gpgsign false \
    && echo test > README.md \
    && git add README.md \
    && git -c init.defaultBranch=main commit -q -m init \
    && git branch -M main \
    && git remote add origin "$FAKE_REPO")

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
VALUES('$gap_id', 'INFRA', 'synthetic test gap', 'open', 'P1', 'should not block on unrelated files');
SQL
}
rm -f "$FAKE_REPO/.chump/state.db"
seed_gap_db "INFRA-PATH-OVERLAP-TEST"

# PATH shim for gh: only the `--json number,title,files` query (the
# path-overlap check) returns a synthetic open PR. Every other invocation
# (fuzzy-match, open-pr-for-gap search) returns an empty array so those
# gates pass through cleanly.
SHIMDIR="$WORK/bin"
mkdir -p "$SHIMDIR"
cat > "$SHIMDIR/gh" <<'SHIM'
#!/usr/bin/env bash
case " $* " in
    *"number,title,files"*)
        cat <<'JSON'
[{"number":8888,"title":"INFRA-OTHER-GAP: unrelated fix","files":[{"path":"src/some_file.rs"}]}]
JSON
        exit 0
        ;;
    *)
        echo "[]"
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

# ── Check: claim blocked when --paths overlaps the mocked PR's files ─────
echo
echo "Check: claim blocked when a declared path overlaps an open PR's files"

rm -f "$AMBIENT"
rm -rf "$WORK/worktrees/chump-infra-path-overlap-test"

set +e
OUT=$(run_claim "INFRA-PATH-OVERLAP-TEST" --paths src/some_file.rs)
RC=$?
set -e

(( RC != 0 )) || fail "claim should have been blocked but exited 0: $OUT"
ok "claim exited non-zero (rc=$RC) when path overlaps an open PR"

grep -q "paths overlap with open PR #8888" <<<"$OUT" \
    && ok "diagnostic surfaces the blocking PR number" \
    || fail "expected 'paths overlap with open PR #8888' in output, got: $OUT"

grep -q "gap INFRA-OTHER-GAP" <<<"$OUT" \
    && ok "diagnostic surfaces the blocking gap ID" \
    || fail "expected 'gap INFRA-OTHER-GAP' in output, got: $OUT"

grep -q "src/some_file.rs" <<<"$OUT" \
    && ok "diagnostic lists the overlapping path" \
    || fail "expected 'src/some_file.rs' in output, got: $OUT"

grep -q -- "--allow-overlap" <<<"$OUT" \
    && ok "diagnostic includes the --allow-overlap escape hatch" \
    || fail "expected --allow-overlap hint in output, got: $OUT"

[[ -f "$AMBIENT" ]] || fail "ambient.jsonl was not created: $AMBIENT"
grep -q '"kind":"claim_path_overlap_blocked"' "$AMBIENT" \
    && ok "claim_path_overlap_blocked event present in ambient.jsonl" \
    || fail "claim_path_overlap_blocked event NOT found ($(cat "$AMBIENT" 2>/dev/null || echo ABSENT))"

grep -q '"claimed_gap":"INFRA-PATH-OVERLAP-TEST"' "$AMBIENT" \
    && ok "ambient event has claimed_gap field" \
    || fail "ambient event missing claimed_gap field"

grep -q '"blocking_pr":8888' "$AMBIENT" \
    && ok "ambient event has blocking_pr field" \
    || fail "ambient event missing blocking_pr field"

grep -q '"blocking_gap":"INFRA-OTHER-GAP"' "$AMBIENT" \
    && ok "ambient event has blocking_gap field" \
    || fail "ambient event missing blocking_gap field"

grep -q '"overlapping_paths":\["src/some_file.rs"\]' "$AMBIENT" \
    && ok "ambient event has overlapping_paths field" \
    || fail "ambient event missing overlapping_paths field"

if [[ -d "$WORK/worktrees/chump-infra-path-overlap-test" ]]; then
    fail "worktree was created despite block — guard must run before worktree add"
else
    ok "no worktree leaked (block fired before worktree create)"
fi

# ── Check: claim with a non-overlapping path is NOT blocked by this gate ─
echo
echo "Check: claim with a different (non-overlapping) path is not blocked"

rm -rf "$WORK/worktrees/chump-infra-path-overlap-test"

set +e
OUT2=$(run_claim "INFRA-PATH-OVERLAP-TEST" --paths docs/unrelated-note.md)
RC2=$?
set -e

if echo "$OUT2" | grep -q "paths overlap with open PR"; then
    fail "claim with a non-overlapping path was blocked by the path-overlap gate: $OUT2"
else
    ok "claim with a non-overlapping path passed the path-overlap gate (rc=$RC2; any failure is unrelated/downstream)"
fi

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
if (( FAIL > 0 )); then
    echo "Failures:"
    for f in "${FAILS[@]}"; do
        echo "  - $f"
    done
    exit 1
fi
exit 0
