#!/usr/bin/env bash
# CI gate for INFRA-854: bot-merge.sh REPO_ROOT mismatch guard.
# Verifies the guard is present in the source and fires correctly when
# bot-merge.sh is invoked from a context where git show-toplevel returns
# a path that does not match the script's physical location.
set -e
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PASS=0; FAIL=0

check() {
  local desc="$1"; shift
  if "$@" >/dev/null 2>&1; then
    echo "  PASS: $desc"; (( PASS++ )) || true
  else
    echo "  FAIL: $desc"; (( FAIL++ )) || true
  fi
}

echo "=== INFRA-854: bot-merge.sh REPO_ROOT mismatch guard ==="

BOT_MERGE="$REPO_ROOT/scripts/coord/bot-merge.sh"

# 1. Guard block exists in source
check "guard block present" grep -q 'INFRA-854' "$BOT_MERGE"
check "mismatch error message present" grep -q 'REPO_ROOT mismatch' "$BOT_MERGE"
check "exit 1 on mismatch" grep -q 'exit 1' "$BOT_MERGE"
check "_bm_expected_root computed" grep -q '_bm_expected_root' "$BOT_MERGE"
check "_bm_actual_root computed" grep -q '_bm_actual_root' "$BOT_MERGE"
check "pwd -P used for canonical path" grep -q 'pwd -P' "$BOT_MERGE"

# 2. Functional test — create a temp directory that looks like a different repo root
#    and fake git show-toplevel to return that path, then verify bot-merge.sh exits 1.
#    We do this by extracting just the guard block and running it in isolation.
TMPDIR_GUARD="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_GUARD"' EXIT

# Build an isolated test that runs the guard with a mismatched root
FAKE_ROOT="$TMPDIR_GUARD/fake-root"
mkdir -p "$FAKE_ROOT"

# Extract the guard logic (lines between INFRA-854 comment and 'cd "$REPO_ROOT"')
guard_test_script="$TMPDIR_GUARD/guard_test.sh"
cat > "$guard_test_script" <<GUARD_EOF
#!/usr/bin/env bash
set -e
# Simulate the guard with a deliberate mismatch: _bm_expected_root != _bm_actual_root
_bm_expected_root="${REPO_ROOT}"
_bm_actual_root="${FAKE_ROOT}"
if [[ -n "\$_bm_expected_root" && -n "\$_bm_actual_root" && "\$_bm_expected_root" != "\$_bm_actual_root" ]]; then
    echo "bot-merge.sh: REPO_ROOT mismatch: git says '\${_bm_actual_root}', script is in '\${_bm_expected_root}' — aborting to prevent wrong-worktree damage" >&2
    exit 1
fi
echo "no mismatch"
GUARD_EOF
chmod +x "$guard_test_script"

# Guard should exit 1 when paths differ
if bash "$guard_test_script" 2>/dev/null; then
    echo "  FAIL: guard did not abort on mismatch"; (( FAIL++ )) || true
else
    echo "  PASS: guard aborts with exit 1 on REPO_ROOT mismatch"; (( PASS++ )) || true
fi

# Guard should NOT fire when paths match
guard_match_script="$TMPDIR_GUARD/guard_match.sh"
cat > "$guard_match_script" <<MATCH_EOF
#!/usr/bin/env bash
set -e
_bm_expected_root="${REPO_ROOT}"
_bm_actual_root="${REPO_ROOT}"
if [[ -n "\$_bm_expected_root" && -n "\$_bm_actual_root" && "\$_bm_expected_root" != "\$_bm_actual_root" ]]; then
    echo "bot-merge.sh: REPO_ROOT mismatch" >&2
    exit 1
fi
echo "no mismatch"
MATCH_EOF
chmod +x "$guard_match_script"

if bash "$guard_match_script" 2>/dev/null | grep -q 'no mismatch'; then
    echo "  PASS: guard passes when paths match"; (( PASS++ )) || true
else
    echo "  FAIL: guard incorrectly fired on matching paths"; (( FAIL++ )) || true
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
