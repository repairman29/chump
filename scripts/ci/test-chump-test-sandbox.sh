#!/usr/bin/env bash
# scripts/ci/test-chump-test-sandbox.sh — INFRA-2088
#
# Smoke test for scripts/coord/lib/test-sandbox.sh: verifies the canonical
# sandbox primitive actually isolates `chump` invocations from the real
# .chump/state.db (the INFRA-2080 class this primitive exists to kill).

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck source=../coord/lib/test-sandbox.sh
# shellcheck disable=SC1091
source "$REPO_ROOT/scripts/coord/lib/test-sandbox.sh"

PASS=0
FAIL=0
pass() { echo "[PASS] $1"; PASS=$((PASS+1)); }
fail() { echo "[FAIL] $1"; FAIL=$((FAIL+1)); }

REAL_STATE_DB="$REPO_ROOT/.chump/state.db"
SANDBOX_TITLE="sandbox-test-title-INFRA-2088-$$"

TMPROOT=$(mktemp -d)
SANDBOX="$TMPROOT/sandbox"
trap 'rm -rf "$TMPROOT"' EXIT

FIXTURE_DIR="$TMPROOT/fixture-gaps"
mkdir -p "$FIXTURE_DIR"
cat > "$FIXTURE_DIR/ZZTEST-001.yaml" <<'YAML'
- id: ZZTEST-001
  domain: ZZTEST
  title: "sandbox-smoke-fixture-gap"
  status: open
  priority: P3
  effort: xs
  acceptance_criteria:
    - "fixture gap used only by test-chump-test-sandbox.sh"
YAML

# ── (a) setup with fixture: state.db exists, env vars all set ─────────────
chump_test_sandbox_setup "$SANDBOX" --seed-yaml "$FIXTURE_DIR"

if [ -f "$SANDBOX/.chump/state.db" ]; then
    pass "(a) sandbox state.db created"
else
    fail "(a) sandbox state.db missing at $SANDBOX/.chump/state.db"
fi

if [ "$CHUMP_HOME" = "$SANDBOX" ] && [ "$CHUMP_REPO" = "$SANDBOX" ] && \
   [ "$CHUMP_REPO_ROOT" = "$SANDBOX" ] && \
   [ "$CHUMP_STATE_DB" = "$SANDBOX/.chump/state.db" ] && \
   [ "$CHUMP_LOCK_DIR" = "$SANDBOX/.chump-locks" ]; then
    pass "(a) all isolation env vars set correctly"
else
    fail "(a) isolation env vars not set as expected (CHUMP_HOME=$CHUMP_HOME CHUMP_REPO=$CHUMP_REPO CHUMP_REPO_ROOT=$CHUMP_REPO_ROOT CHUMP_STATE_DB=$CHUMP_STATE_DB CHUMP_LOCK_DIR=$CHUMP_LOCK_DIR)"
fi

if chump gap list --json 2>/dev/null | grep -q "ZZTEST-001"; then
    pass "(a) fixture gap ZZTEST-001 present in sandbox state.db"
else
    fail "(a) fixture gap ZZTEST-001 NOT found in sandbox state.db"
fi

# ── (b) chump gap reserve lands in sandbox state.db, not real ─────────────
CHUMP_GAP_RESERVE_SKIP_PR=1 CHUMP_RESERVE_SCAN_OPEN_PRS=0 CHUMP_ALLOW_MAIN_WORKTREE=1 \
    chump gap reserve --domain ZZTEST --title "$SANDBOX_TITLE" \
    --no-outcome-required --force >/dev/null 2>&1

if chump gap list --json 2>/dev/null | grep -q "$SANDBOX_TITLE"; then
    pass "(b) reserved gap landed in sandbox state.db"
else
    fail "(b) reserved gap NOT found in sandbox state.db"
fi

if sqlite3 "$REAL_STATE_DB" "SELECT title FROM gaps;" 2>/dev/null | grep -q "$SANDBOX_TITLE"; then
    fail "(b) reserved gap LEAKED into real state.db at $REAL_STATE_DB"
else
    pass "(b) real state.db does not contain the sandbox-reserved gap"
fi

# ── (c) cleanup removes everything + unsets env vars ───────────────────────
chump_test_sandbox_cleanup "$SANDBOX"

if [ -d "$SANDBOX" ]; then
    fail "(c) sandbox dir still exists after cleanup"
else
    pass "(c) sandbox dir removed"
fi

if [ -z "${CHUMP_HOME:-}" ] && [ -z "${CHUMP_REPO:-}" ] && [ -z "${CHUMP_REPO_ROOT:-}" ] && \
   [ -z "${CHUMP_STATE_DB:-}" ] && [ -z "${CHUMP_LOCK_DIR:-}" ]; then
    pass "(c) isolation env vars unset after cleanup"
else
    fail "(c) isolation env vars still set after cleanup"
fi

# ── (d) real state.db untouched by the whole exercise ──────────────────────
if sqlite3 "$REAL_STATE_DB" "SELECT id FROM gaps;" 2>/dev/null | grep -q "^ZZTEST-"; then
    fail "(d) real state.db was polluted with a ZZTEST- gap"
else
    pass "(d) real state.db has no ZZTEST- gaps — sandbox never bled through"
fi

echo ""
echo "=== $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
