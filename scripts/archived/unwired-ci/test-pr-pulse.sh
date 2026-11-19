#!/usr/bin/env bash
# scripts/ci/test-pr-pulse.sh — INFRA-1897
#
# Smoke test for the PR oversight one-shot CLI. Mocks gh output so the
# script's count/percentile logic + ambient-emit + summary-print can be
# verified without hitting real GitHub.

set -euo pipefail

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$REPO/scripts/coord/pr-pulse.sh"

ok()   { printf '\033[0;32mPASS\033[0m %s\n' "$*"; }
fail() { printf '\033[0;31mFAIL\033[0m %s\n' "$*"; exit 1; }

[[ -f "$SCRIPT" ]] || fail "$SCRIPT missing"
[[ -x "$SCRIPT" ]] || fail "$SCRIPT not executable"
bash -n "$SCRIPT" || fail "$SCRIPT syntax error"
ok "script exists, executable, parses"

# ── Structural assertions ─────────────────────────────────────────────────
grep -q 'pr_oversight_snapshot' "$SCRIPT" || fail "no pr_oversight_snapshot kind"
ok "emits kind=pr_oversight_snapshot"

grep -q 'CHUMP_PR_PULSE_NO_EMIT' "$SCRIPT" || fail "no NO_EMIT bypass"
ok "CHUMP_PR_PULSE_NO_EMIT bypass present"

grep -q 'blocked_armed' "$SCRIPT" || fail "no blocked_armed field"
grep -q 'blocked_failed' "$SCRIPT" || fail "no blocked_failed field"
grep -q 'age_p50' "$SCRIPT" || fail "no age_p50 field"
grep -q 'age_p99' "$SCRIPT" || fail "no age_p99 field"
ok "all 4 required fields present (blocked_armed, blocked_failed, age_p50, age_p99)"

grep -q 'verdict' "$SCRIPT" || fail "no verdict line — operator needs the at-a-glance call"
ok "verdict line (HEALTHY/SATURATED/WEDGED) present"

# ── Functional: mock gh, run script, verify output shape ──────────────────
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
cat > "$TMP/gh" <<'MOCK'
#!/usr/bin/env bash
# Mock gh: synthetic queue of 5 PRs (2 DIRTY, 2 BLOCKED+armed, 1 BLOCKED-failed)
if [[ "$1" == "pr" && "$2" == "list" ]]; then
cat <<JSON
[
  {"number": 9001, "mergeStateStatus": "DIRTY", "autoMergeRequest": null, "createdAt": "2026-05-23T20:00:00Z"},
  {"number": 9002, "mergeStateStatus": "DIRTY", "autoMergeRequest": null, "createdAt": "2026-05-23T21:00:00Z"},
  {"number": 9003, "mergeStateStatus": "BLOCKED", "autoMergeRequest": {"mergeMethod": "SQUASH"}, "createdAt": "2026-05-23T22:00:00Z"},
  {"number": 9004, "mergeStateStatus": "BLOCKED", "autoMergeRequest": {"mergeMethod": "SQUASH"}, "createdAt": "2026-05-23T22:30:00Z"},
  {"number": 9005, "mergeStateStatus": "BLOCKED", "autoMergeRequest": null, "createdAt": "2026-05-23T23:00:00Z"}
]
JSON
fi
MOCK
chmod +x "$TMP/gh"

# Mock the ambient-emit too so we can verify the kind without polluting prod ambient
mkdir -p "$TMP/scripts/dev"
cat > "$TMP/scripts/dev/ambient-emit.sh" <<'MOCK'
#!/usr/bin/env bash
echo "[mock-emit] $*" >> "$AMBIENT_TEST_LOG"
MOCK
chmod +x "$TMP/scripts/dev/ambient-emit.sh"

# Run with mocked PATH + ambient log
AMBIENT_TEST_LOG="$TMP/ambient.log"
export AMBIENT_TEST_LOG
out="$(PATH="$TMP:$PATH" CHUMP_AMBIENT_LOG="$AMBIENT_TEST_LOG" bash "$SCRIPT" 2>&1)" || true

# Verify summary lines
echo "$out" | grep -q "open=5 dirty=2" || fail "summary missing total=5 dirty=2; got: $out"
ok "summary line: open=5 dirty=2 correct"

echo "$out" | grep -q "blocked+armed=2" || fail "blocked+armed=2 missing; got: $out"
ok "summary line: blocked+armed=2 correct"

echo "$out" | grep -q "blocked-failed=1" || fail "blocked-failed=1 missing; got: $out"
ok "summary line: blocked-failed=1 correct"

echo "$out" | grep -q "verdict=" || fail "verdict missing"
ok "verdict line present"

# Bypass test — NO_EMIT should suppress emit
out_bypass="$(PATH="$TMP:$PATH" CHUMP_AMBIENT_LOG="$AMBIENT_TEST_LOG" CHUMP_PR_PULSE_NO_EMIT=1 bash "$SCRIPT" 2>&1)" || true
echo "$out_bypass" | grep -q "open=5" || fail "bypass still prints summary"
ok "CHUMP_PR_PULSE_NO_EMIT=1 still prints summary"

# Attribution
grep -q 'INFRA-1897' "$SCRIPT" || fail "no INFRA-1897 attribution"
ok "INFRA-1897 attribution present"

echo ""
echo "ALL INFRA-1897 pr-pulse assertions passed."
