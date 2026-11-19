#!/usr/bin/env bash
# INFRA-1882: smoke test for `chump scan <repo-path>` (2026 demo #2, repo
# takeover opener).
#
# Asserts:
#   1. --help exits 0
#   2. missing arg exits 2
#   3. non-existent path exits 1
#   4. non-git dir exits 1
#   5. a synthetic fixture repo with known-shape findings (>=3 TODOs in one
#      file, no LICENSE, no README, no CI workflow, missing .gitignore
#      entries) files exactly --max-gaps gaps into the FIXTURE's own
#      .chump/state.db (not ours), and emits chump_scan_complete with
#      gaps_filed == max_gaps and total_findings >= max_gaps.
set -euo pipefail
ROOT="$(git rev-parse --show-toplevel)"
cd "$ROOT"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

CHUMP="${CHUMP_BIN:-}"
if [[ -n "$CHUMP" ]] && [[ ! -x "$CHUMP" ]]; then
  CHUMP=""
fi
find_chump_bin() {
  if [[ -n "${CARGO_TARGET_DIR:-}" ]] && [[ -x "$CARGO_TARGET_DIR/debug/chump" ]]; then
    echo "$CARGO_TARGET_DIR/debug/chump"
  elif [[ -x "$ROOT/target/debug/chump" ]]; then
    echo "$ROOT/target/debug/chump"
  fi
}
if [[ -z "$CHUMP" ]]; then
  CHUMP="$(find_chump_bin)"
fi
if [[ -z "$CHUMP" ]]; then
  echo "test-chump-scan: building chump …" >&2
  if ! command -v cargo >/dev/null 2>&1; then
    echo "  SKIP: cargo not on PATH" >&2
    exit 0
  fi
  cargo build -q --bin chump 2>&1 || {
    echo "  SKIP: cargo build failed" >&2
    exit 0
  }
  CHUMP="$(find_chump_bin)"
  if [[ -z "$CHUMP" ]]; then
    echo "  SKIP: chump binary still missing after cargo build" >&2
    exit 0
  fi
fi

# Isolate our own ambient writes from the real .chump-locks/ambient.jsonl —
# chump_scan_complete is emitted to repo_path::repo_root(), which honours
# CHUMP_REPO (same pattern as test-ingest-librarian-smoke.sh).
CHUMP_HOME_FIXTURE="$TMP/chump-home"
mkdir -p "$CHUMP_HOME_FIXTURE"
export CHUMP_REPO="$CHUMP_HOME_FIXTURE"
AMBIENT="$CHUMP_HOME_FIXTURE/.chump-locks/ambient.jsonl"

fail=0

echo "[1/5] --help exits 0"
if ! "$CHUMP" scan --help >/dev/null 2>&1; then
  echo "  FAIL: --help did not exit 0"
  fail=1
fi

echo "[2/5] missing arg exits 2"
set +e
"$CHUMP" scan >/dev/null 2>&1
rc=$?
set -e
if [[ "$rc" -ne 2 ]]; then
  echo "  FAIL: missing-arg exit code was $rc, expected 2"
  fail=1
fi

echo "[3/5] non-existent path exits 1"
set +e
"$CHUMP" scan "$TMP/does-not-exist" >/dev/null 2>&1
rc=$?
set -e
if [[ "$rc" -ne 1 ]]; then
  echo "  FAIL: non-existent-path exit code was $rc, expected 1"
  fail=1
fi

echo "[4/5] non-git dir exits 1"
NOGIT="$TMP/nogit"
mkdir -p "$NOGIT"
set +e
"$CHUMP" scan "$NOGIT" >/dev/null 2>&1
rc=$?
set -e
if [[ "$rc" -ne 1 ]]; then
  echo "  FAIL: non-git-dir exit code was $rc, expected 1"
  fail=1
fi

echo "[5/5] fixture repo files exactly --max-gaps gaps into its own state.db"
FIXTURE="$TMP/fixture-repo"
mkdir -p "$FIXTURE/.git" "$FIXTURE/src"
{
  echo 'fn main() {'
  echo '    // TODO: one'
  echo '    // TODO: two'
  echo '    // FIXME: three'
  echo '    // XXX: four'
  echo '}'
} > "$FIXTURE/src/main.rs"
# No LICENSE, no README.md, no .github/workflows/, no .gitignore —
# findings: todo-density(1) + LICENSE(1) + README(1) + CI(1) + gitignore(1) = 5

set +e
OUT="$("$CHUMP" scan "$FIXTURE" --max-gaps 3 2>&1)"
rc=$?
set -e
if [[ "$rc" -ne 0 ]]; then
  echo "  FAIL: scan on fixture repo exited $rc, expected 0"
  echo "$OUT"
  fail=1
fi

if [[ ! -f "$FIXTURE/.chump/state.db" ]]; then
  echo "  FAIL: $FIXTURE/.chump/state.db was not created"
  fail=1
fi

filed_count="$(sqlite3 "$FIXTURE/.chump/state.db" "SELECT COUNT(*) FROM gaps;" 2>/dev/null || echo 0)"
if [[ "$filed_count" -ne 3 ]]; then
  echo "  FAIL: expected exactly 3 gaps filed into fixture state.db, got $filed_count"
  fail=1
fi

if [[ ! -f "$AMBIENT" ]] || ! grep -q '"kind":"chump_scan_complete"' "$AMBIENT"; then
  echo "  FAIL: chump_scan_complete not found in ambient stream"
  fail=1
fi
if ! grep '"kind":"chump_scan_complete"' "$AMBIENT" | grep -q '"gaps_filed":3'; then
  echo "  FAIL: chump_scan_complete did not report gaps_filed=3"
  fail=1
fi
if ! grep '"kind":"chump_scan_complete"' "$AMBIENT" | grep -q '"total_findings":5'; then
  echo "  FAIL: chump_scan_complete did not report total_findings=5"
  fail=1
fi

if [[ "$fail" -eq 0 ]]; then
  echo "test-chump-scan: PASS"
else
  echo "test-chump-scan: FAIL"
fi
exit "$fail"
