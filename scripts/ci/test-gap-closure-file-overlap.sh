#!/usr/bin/env bash
# test-gap-closure-file-overlap.sh — CREDIBLE-1004 (CREDIBLE-268 slice)
#
# Unit-tests the file-overlap check (check_file_overlap) in
# test-gap-closure-consistency.sh: a done gap whose PR is merged but touched
# NONE of the files its acceptance_criteria name must fail the gate under
# --strict. A control scenario (PR touches a referenced file) must still pass.
#
# Stubs `gh` on PATH so this never talks to real GitHub.
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
GATE="$REPO_ROOT/scripts/ci/test-gap-closure-consistency.sh"

PASS=0; FAIL=0
check() {
  local desc="$1" expect_status="$2"; shift 2
  local out status
  out="$("$@" 2>&1)" && status=0 || status=$?
  if [[ "$status" -eq "$expect_status" ]]; then
    echo "  PASS: $desc"; (( PASS++ )) || true
  else
    echo "  FAIL: $desc (expected exit $expect_status, got $status)"
    echo "$out" | sed 's/^/      /'
    (( FAIL++ )) || true
  fi
}

echo "=== CREDIBLE-1004: gap-closure file-overlap unit tests ==="

if ! command -v sqlite3 &>/dev/null; then
  echo "  SKIP: sqlite3 not found"
  exit 0
fi

TMPDIR_TEST="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_TEST"' EXIT
unset CHUMP_REPO CHUMP_LOCK_DIR

FAKE_BIN="$TMPDIR_TEST/bin"
mkdir -p "$FAKE_BIN"

# Fake `gh` — routes on argv. PR #90001 (no overlap): files list excludes the
# AC-referenced path. PR #90002 (overlap): files list includes it.
cat > "$FAKE_BIN/gh" <<'EOF'
#!/usr/bin/env bash
args="$*"
case "$args" in
  "api /rate_limit --silent") exit 0 ;;
  "pr view 90001 --json mergedAt --jq .mergedAt") echo "2026-09-01T00:00:00Z" ;;
  "pr view 90001 --json files --jq .files[].path") echo "unrelated/other.rs" ;;
  "pr view 90002 --json mergedAt --jq .mergedAt") echo "2026-09-01T00:00:00Z" ;;
  "pr view 90002 --json files --jq .files[].path") echo "scripts/ci/lib/gate-emit.sh" ;;
  *) echo "null" ;;
esac
exit 0
EOF
chmod +x "$FAKE_BIN/gh"

mk_fixture_db() {
  local db="$1" gap_id="$2" pr_num="$3" ac_text="$4"
  mkdir -p "$(dirname "$db")"
  sqlite3 "$db" "
    CREATE TABLE gaps (
      id TEXT PRIMARY KEY,
      title TEXT,
      status TEXT,
      priority TEXT,
      effort TEXT,
      closed_pr INTEGER,
      depends_on TEXT,
      acceptance_criteria TEXT
    );
    INSERT INTO gaps VALUES('$gap_id','test gap','done','P2','xs',$pr_num,NULL,'$ac_text');
  "
}

# ── Scenario 1: PR closes a gap without touching any referenced files ──────
DB1="$TMPDIR_TEST/no-overlap/.chump/state.db"
mk_fixture_db "$DB1" "NOOVERLAP-001" 90001 "Fix the bug in scripts/ci/lib/gate-emit.sh"

check "no file-overlap → gate fails under --strict" 1 \
  bash -c "PATH='$FAKE_BIN:$PATH' CHUMP_STATE_DB='$DB1' CHUMP_GH_REQUIRED=1 CHUMP_GH_PROBE_SKIP=1 bash '$GATE' --strict"

check "no file-overlap → warning names the gap and PR" 0 \
  bash -c "PATH='$FAKE_BIN:$PATH' CHUMP_STATE_DB='$DB1' CHUMP_GH_REQUIRED=1 CHUMP_GH_PROBE_SKIP=1 bash '$GATE' --strict 2>&1 | grep -q 'NOOVERLAP-001: PR #90001 touched none of the files'"

# ── Scenario 2 (control): PR touches a file its ACs name → passes ─────────
DB2="$TMPDIR_TEST/overlap/.chump/state.db"
mk_fixture_db "$DB2" "OVERLAP-001" 90002 "Fix the bug in scripts/ci/lib/gate-emit.sh"

check "file-overlap present → gate passes under --strict" 0 \
  bash -c "PATH='$FAKE_BIN:$PATH' CHUMP_STATE_DB='$DB2' CHUMP_GH_REQUIRED=1 CHUMP_GH_PROBE_SKIP=1 bash '$GATE' --strict"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
