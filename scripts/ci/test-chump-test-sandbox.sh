#!/usr/bin/env bash
# scripts/ci/test-chump-test-sandbox.sh — INFRA-2088
#
# Smoke test for scripts/coord/lib/test-sandbox.sh: the canonical
# chump_test_sandbox_setup / chump_test_sandbox_cleanup primitive.
#
# Run from repo root: bash scripts/ci/test-chump-test-sandbox.sh

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CHUMP_BIN="${CARGO_TARGET_DIR:-$REPO_ROOT/target}/debug/chump"

PASS=0
FAIL=0
pass() { echo "[PASS] $1"; PASS=$((PASS+1)); }
fail() { echo "[FAIL] $1" >&2; FAIL=$((FAIL+1)); }

if [[ ! -x "$CHUMP_BIN" ]]; then
    echo "SKIP: $CHUMP_BIN not built — run 'cargo build --bin chump' first" >&2
    exit 0
fi

# shellcheck source=scripts/coord/lib/test-sandbox.sh
source "$REPO_ROOT/scripts/coord/lib/test-sandbox.sh"
export CHUMP_TEST_SANDBOX_BIN="$CHUMP_BIN"

TMPROOT=$(mktemp -d)
trap 'rm -rf "$TMPROOT"' EXIT

FIXTURE="$TMPROOT/fixture.yaml"
cat > "$FIXTURE" <<'YAML'
gaps:
- id: SBX-001
  status: open
  title: "sandbox-test-title fixture gap"
- id: SBX-002
  status: done
  title: "sandbox-test-title second fixture gap"
YAML

# ── (a) setup + verify state.db seeded + env vars set ────────────────────
SANDBOX="$TMPROOT/sandbox-a"
chump_test_sandbox_setup "$SANDBOX" --seed-yaml "$FIXTURE"

if [[ -f "$SANDBOX/.chump/state.db" ]]; then
    pass "(a) state.db created at \$sandbox/.chump/state.db"
else
    fail "(a) state.db not found at $SANDBOX/.chump/state.db"
fi

got_count=$(CHUMP_HOME="$SANDBOX" CHUMP_REPO="$SANDBOX" CHUMP_REPO_ROOT="$SANDBOX" \
    "$CHUMP_BIN" gap list --status open --json 2>/dev/null | grep -c '"SBX-001"' || true)
if [[ "$got_count" -ge 1 ]]; then
    pass "(a) seeded gap SBX-001 visible via chump gap list in sandbox"
else
    fail "(a) SBX-001 not found in sandbox gap list"
fi

for var in CHUMP_HOME CHUMP_REPO CHUMP_REPO_ROOT CHUMP_STATE_DB CHUMP_LOCK_DIR; do
    val="${!var:-}"
    if [[ -n "$val" ]]; then
        pass "(a) $var exported ($val)"
    else
        fail "(a) $var not exported after setup"
    fi
done

# ── (b) chump gap reserve from sandbox lands in sandbox db, not real db ──
# "Real" here is the main checkout's own state.db (git-common-dir parent),
# NOT this linked worktree (which has no state.db of its own). Every
# isolation var is explicitly unset (via `env -u`) for these checks so a
# var still exported from chump_test_sandbox_setup can't leak through and
# make the check silently read the sandbox db instead of the real one.
_GIT_COMMON_DIR="$(git -C "$REPO_ROOT" rev-parse --git-common-dir 2>/dev/null || echo ".git")"
if [[ "$_GIT_COMMON_DIR" == ".git" ]]; then
    REAL_ROOT="$REPO_ROOT"
elif [[ "$_GIT_COMMON_DIR" = /* ]]; then
    REAL_ROOT="$(cd "$_GIT_COMMON_DIR/.." && pwd)"
else
    REAL_ROOT="$(cd "$REPO_ROOT/$_GIT_COMMON_DIR/.." && pwd)"
fi

query_real_db() {
    env -u CHUMP_HOME -u CHUMP_REPO -u CHUMP_REPO_ROOT -u CHUMP_STATE_DB -u CHUMP_LOCK_DIR \
        CHUMP_HOME="$REAL_ROOT" CHUMP_REPO="$REAL_ROOT" CHUMP_REPO_ROOT="$REAL_ROOT" \
        "$CHUMP_BIN" gap list --status open --json 2>/dev/null | grep -c "sandbox-test-title" || true
}

before_real=$(query_real_db)

(
    cd "$SANDBOX"
    CHUMP_HOME="$SANDBOX" CHUMP_REPO="$SANDBOX" CHUMP_REPO_ROOT="$SANDBOX" \
    CHUMP_GAP_RESERVE_NO_OUTCOME=1 CHUMP_ALLOW_MAIN_WORKTREE=1 \
    FLEET_029_AMBIENT_GLANCE_SKIP=1 \
    "$CHUMP_BIN" gap reserve --domain SBX --title "sandbox-test-title reserve smoke" \
        >/dev/null 2>&1
) || true

reserved_in_sandbox=$(CHUMP_HOME="$SANDBOX" CHUMP_REPO="$SANDBOX" CHUMP_REPO_ROOT="$SANDBOX" \
    "$CHUMP_BIN" gap list --status open --json 2>/dev/null | grep -c "sandbox-test-title" || true)
if [[ "$reserved_in_sandbox" -ge 1 ]]; then
    pass "(b) chump gap reserve landed in sandbox state.db"
else
    fail "(b) reserved gap not found in sandbox state.db"
fi

after_real=$(query_real_db)
if [[ "$before_real" -eq "$after_real" ]]; then
    pass "(d) real state.db unchanged after sandbox use (no sandbox-test-title gap leaked)"
else
    fail "(d) real state.db gained a sandbox-test-title gap — isolation leak (before=$before_real after=$after_real)"
fi

# ── (c) cleanup removes everything ────────────────────────────────────────
chump_test_sandbox_cleanup "$SANDBOX"
if [[ ! -e "$SANDBOX" ]]; then
    pass "(c) cleanup removed sandbox dir"
else
    fail "(c) sandbox dir still exists after cleanup"
fi
if [[ -z "${CHUMP_HOME:-}" ]]; then
    pass "(c) cleanup unset CHUMP_HOME"
else
    fail "(c) CHUMP_HOME still set after cleanup"
fi

echo ""
echo "Passed: $PASS  Failed: $FAIL"
[[ "$FAIL" -eq 0 ]]
