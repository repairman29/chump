#!/usr/bin/env bash
# scripts/ci/test-auto-merge-rearm-daemon.sh — INFRA-2309
#
# Smoke test for scripts/coord/auto-merge-rearm-daemon.sh
#
# Tests:
#   1. CLEAN+in-allowlist PR gets armed (dry-run logs it, no real gh merge)
#   2. CLEAN+not-in-allowlist PR gets skipped
#   3. Non-CLEAN (BEHIND) PR is ignored entirely
#   4. Already-armed (autoMergeRequest set) CLEAN PR is ignored
#   5. Open mode (CHUMP_AUTO_MERGE_REARM_OPEN=1) arms feat( PRs too
#
# Usage:
#   bash scripts/ci/test-auto-merge-rearm-daemon.sh
# Exit 0 = all assertions pass. Exit 1 = failure.

set -euo pipefail
# shellcheck disable=SC1091
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DAEMON="$REPO_ROOT/scripts/coord/auto-merge-rearm-daemon.sh"

PASS=0
FAIL=0

_pass() { echo "  PASS: $*"; PASS=$((PASS + 1)); }
_fail() { echo "  FAIL: $*" >&2; FAIL=$((FAIL + 1)); }
_assert_contains() {
  local label="$1" haystack="$2" needle="$3"
  if echo "$haystack" | grep -qF "$needle"; then
    _pass "$label"
  else
    _fail "$label — needle='$needle' not found in output"
  fi
}
_assert_not_contains() {
  local label="$1" haystack="$2" needle="$3"
  if ! echo "$haystack" | grep -qF "$needle"; then
    _pass "$label"
  else
    _fail "$label — needle='$needle' unexpectedly found in output"
  fi
}

echo "=== test-auto-merge-rearm-daemon: INFRA-2309 ==="

# ── Setup: temp dir for fake gh ───────────────────────────────────────────
TMPDIR_TEST="$(mktemp -d /tmp/test-auto-merge-rearm-XXXXXX)"
trap 'rm -rf "$TMPDIR_TEST"' EXIT

FAKE_GH="$TMPDIR_TEST/gh"
FAKE_GH_LOG="$TMPDIR_TEST/gh-calls.log"
# Write synthetic PR JSON to a file (avoids SC2089 multi-line string warning)
FAKE_PR_FILE="$TMPDIR_TEST/prs.json"
cat > "$FAKE_PR_FILE" <<'PREOF'
[
  {"number":101,"title":"fix(ci): correct timeout","mergeStateStatus":"CLEAN","autoMergeRequest":null,"createdAt":"2026-05-30T10:00:00Z","author":{"login":"bot"},"headRefName":"fix-timeout"},
  {"number":102,"title":"feat(api): new endpoint","mergeStateStatus":"CLEAN","autoMergeRequest":null,"createdAt":"2026-05-30T10:01:00Z","author":{"login":"bot"},"headRefName":"feat-api"},
  {"number":103,"title":"fix(db): index","mergeStateStatus":"BEHIND","autoMergeRequest":null,"createdAt":"2026-05-30T10:02:00Z","author":{"login":"bot"},"headRefName":"fix-db"},
  {"number":104,"title":"fix(auth): token","mergeStateStatus":"CLEAN","autoMergeRequest":{"enabledAt":"2026-05-30T09:00:00Z"},"createdAt":"2026-05-30T10:03:00Z","author":{"login":"bot"},"headRefName":"fix-auth"}
]
PREOF

# Fake gh: returns synthetic PR JSON for pr list; records merge calls
cat > "$FAKE_GH" <<GHEOF
#!/usr/bin/env bash
echo "\$@" >> "$FAKE_GH_LOG"
if [[ "\${1:-}" = "pr" && "\${2:-}" = "list" ]]; then
  cat "$FAKE_PR_FILE"
  exit 0
fi
if [[ "\${1:-}" = "pr" && "\${2:-}" = "merge" ]]; then
  exit 0
fi
exit 0
GHEOF
chmod +x "$FAKE_GH"

# ── Test 1: DRY_RUN tick — armed=1 skipped=1, no real merge calls ────────
echo ""
echo "-- Test 1: dry-run tick --"

GH_STDERR_1="$TMPDIR_TEST/t1-stderr.txt"
rm -f "$FAKE_GH_LOG"
PATH="$TMPDIR_TEST:$PATH" \
  CHUMP_AUTO_MERGE_REARM_DRY_RUN=1 \
  bash "$DAEMON" tick 2>"$GH_STDERR_1" || true

GH_CALLS_1="$(cat "$FAKE_GH_LOG" 2>/dev/null || echo "")"
STDERR_1="$(cat "$GH_STDERR_1")"

_assert_contains "T1: armed PR 101 dry-run logged" "$STDERR_1" "would arm PR #101"
_assert_contains "T1: skipped PR 102 logged" "$STDERR_1" "skipped PR #102"
_assert_not_contains "T1: PR 103 (BEHIND) not mentioned" "$STDERR_1" "#103"
_assert_not_contains "T1: PR 104 (already armed) not mentioned" "$STDERR_1" "#104"

if echo "$GH_CALLS_1" | grep -q "pr merge"; then
  _fail "T1: gh pr merge was called in dry-run mode (should be suppressed)"
else
  _pass "T1: gh pr merge not called in dry-run mode"
fi

# ── Test 2: Live tick — check gh pr merge called for 101 but not 102 ─────
echo ""
echo "-- Test 2: live tick --"

GH_STDERR_2="$TMPDIR_TEST/t2-stderr.txt"
rm -f "$FAKE_GH_LOG"
PATH="$TMPDIR_TEST:$PATH" \
  bash "$DAEMON" tick 2>"$GH_STDERR_2" || true

GH_CALLS_2="$(cat "$FAKE_GH_LOG" 2>/dev/null || echo "")"
STDERR_2="$(cat "$GH_STDERR_2")"

_assert_contains "T2: armed PR 101 in live mode" "$STDERR_2" "armed PR #101"
_assert_contains "T2: skipped PR 102 in live mode" "$STDERR_2" "skipped PR #102"
_assert_not_contains "T2: PR 103 (BEHIND) not mentioned" "$STDERR_2" "#103"

if echo "$GH_CALLS_2" | grep -q "pr merge 101"; then
  _pass "T2: gh pr merge called for PR 101"
else
  _fail "T2: gh pr merge was NOT called for PR 101"
fi
if echo "$GH_CALLS_2" | grep -q "pr merge 102"; then
  _fail "T2: gh pr merge was called for PR 102 (should be skipped)"
else
  _pass "T2: gh pr merge NOT called for PR 102 (correctly skipped)"
fi

# ── Test 3: OPEN_MODE bypasses allowlist — feat( PR 102 gets armed ────────
echo ""
echo "-- Test 3: open mode (CHUMP_AUTO_MERGE_REARM_OPEN=1) --"

GH_STDERR_3="$TMPDIR_TEST/t3-stderr.txt"
rm -f "$FAKE_GH_LOG"
PATH="$TMPDIR_TEST:$PATH" \
  CHUMP_AUTO_MERGE_REARM_OPEN=1 \
  CHUMP_AUTO_MERGE_REARM_DRY_RUN=1 \
  bash "$DAEMON" tick 2>"$GH_STDERR_3" || true

STDERR_3="$(cat "$GH_STDERR_3")"
_assert_contains "T3: PR 101 armed in open+dry mode" "$STDERR_3" "#101"
_assert_contains "T3: PR 102 armed in open+dry mode (feat bypassed)" "$STDERR_3" "#102"
_assert_not_contains "T3: PR 103 (BEHIND) still not mentioned in open mode" "$STDERR_3" "#103"

# ── Test 4: PR 104 (CLEAN but already armed) is ignored ───────────────────
echo ""
echo "-- Test 4: already-armed PR ignored --"
# STDERR_2 from Test 2 is good enough — PR 104 should not appear
_assert_not_contains "T4: PR 104 (already armed) not processed in live tick" "$STDERR_2" "#104"

# ── Test 5: tick summary line emitted ────────────────────────────────────
echo ""
echo "-- Test 5: tick summary line --"
_assert_contains "T5: tick summary emitted" "$STDERR_2" "tick complete"
_assert_contains "T5: armed count in summary" "$STDERR_2" "armed:1"
_assert_contains "T5: skipped count in summary" "$STDERR_2" "skipped:1"

# ── Results ────────────────────────────────────────────────────────────────
echo ""
echo "=== Results: PASS=${PASS} FAIL=${FAIL} ==="
if [[ "$FAIL" -gt 0 ]]; then
  echo "FAIL" >&2
  exit 1
fi
echo "PASS"
exit 0
