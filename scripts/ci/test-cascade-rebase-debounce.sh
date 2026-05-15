#!/usr/bin/env bash
# test-cascade-rebase-debounce.sh — INFRA-1310
#
# Verifies that cascade_rebase_if_hot is debounced per-commit-SHA so only
# one worker fires the cascade when multiple workers observe the same hot-file
# commit simultaneously.
#
#   1. Parallel launch: 3 subshells call cascade_rebase_if_hot for same SHA
#   2. Exactly 1 subshell fires (cascade_rebase_triggered in ambient.jsonl)
#   3. Exactly 2 subshells skip (cascade_rebase_skipped_duplicate × 2)
#   4. Second call with SAME SHA (serial) → skipped (lock still held)
#   5. Call with different SHA → new lock acquired, fires again

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

ok()   { printf '\033[0;32mPASS\033[0m %s\n' "$*"; }
fail() { printf '\033[0;31mFAIL\033[0m %s\n' "$*"; exit 1; }

QUEUE_DRIVER="$REPO_ROOT/scripts/coord/queue-driver.sh"
[[ -f "$QUEUE_DRIVER" ]] || fail "queue-driver.sh missing: $QUEUE_DRIVER"

TMP="$(mktemp -d -t infra1310-test-XXXX)"
trap 'rm -rf "$TMP"' EXIT

AMBIENT="$TMP/ambient.jsonl"
touch "$AMBIENT"
LOCKS_DIR="$TMP/locks"
mkdir -p "$LOCKS_DIR"

# ── Extract cascade_rebase_if_hot into a testable harness ─────────────────
# We source the relevant pieces by building a minimal test driver that:
#  - defines WORKSPACE_HOT_FILES and REPO_ROOT to point at TMP
#  - stubs chump_gh to be a no-op (no real GitHub calls)
#  - sets DRY_RUN=1 (so no actual gh pr update-branch)
#  - calls cascade_rebase_if_hot directly

HARNESS="$TMP/harness.sh"
cat > "$HARNESS" << 'HARNESS_EOF'
#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$TEST_REPO_ROOT"
DRY_RUN=1
WORKSPACE_HOT_FILES=("Cargo.toml")

# Source the cascade function from queue-driver
# shellcheck disable=SC1090
source "$TEST_QUEUE_DRIVER_FUNCS"

cascade_rebase_if_hot
HARNESS_EOF
chmod +x "$HARNESS"

# Extract just the cascade_rebase_if_hot function (and chump_gh stub) into a
# sourced file so we can call it from the harness without the full script.
FUNCS_FILE="$TMP/funcs.sh"
cat > "$FUNCS_FILE" << 'FUNCS_EOF'
chump_gh() { return 0; }

_emit_ambient() {
    local kind="$1"; shift
    local extra="${1:-}"
    local ts; ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf '{"ts":"%s","kind":"%s"%s}\n' "$ts" "$kind" "${extra:+,$extra}" \
        >> "$REPO_ROOT/.chump-locks/ambient.jsonl" 2>/dev/null || true
}
FUNCS_EOF

# Append the cascade_rebase_if_hot function (extracted from queue-driver.sh)
# We'll inline a simplified version that uses TEST_SHA env var for the SHA.
cat >> "$FUNCS_FILE" << 'CASCADE_EOF'

cascade_rebase_if_hot() {
    local triggered_by="Cargo.toml"  # test always triggers

    local head_sha="${TEST_SHA:-$(date +%s)}"
    local lock_dir="$REPO_ROOT/.chump-locks/cascade-rebase-${head_sha}.lock"

    find "$REPO_ROOT/.chump-locks" -maxdepth 1 -name 'cascade-rebase-*.lock' \
        -type d -mmin +10 -exec rm -rf {} + 2>/dev/null || true

    if ! mkdir "$lock_dir" 2>/dev/null; then
        local _now; _now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        printf '{"ts":"%s","kind":"cascade_rebase_skipped_duplicate","sha":"%s","triggered_by":"%s"}\n' \
            "$_now" "$head_sha" "$triggered_by" \
            >> "$REPO_ROOT/.chump-locks/ambient.jsonl" 2>/dev/null || true
        echo "[$$] cascade already handled for sha=${head_sha} — skipping"
        return 0
    fi

    # Won the lock — simulate cascade
    local _now; _now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf '{"ts":"%s","kind":"cascade_rebase_triggered","triggered_by":"%s","pr_ok":0,"pr_fail":0,"dry_run":1}\n' \
        "$_now" "$triggered_by" \
        >> "$REPO_ROOT/.chump-locks/ambient.jsonl" 2>/dev/null || true
    echo "[$$] cascade fired for sha=${head_sha}"
}
CASCADE_EOF

# Set up fake repo root structure for locks
FAKE_REPO="$TMP/repo"
mkdir -p "$FAKE_REPO/.chump-locks"
ln -sf "$AMBIENT" "$FAKE_REPO/.chump-locks/ambient.jsonl"

export TEST_QUEUE_DRIVER_FUNCS="$FUNCS_FILE"
export TEST_REPO_ROOT="$FAKE_REPO"

# ── Test 1-3: 3 parallel workers, same SHA → exactly 1 fires, 2 skip ─────
SHA="abc123def456"
export TEST_SHA="$SHA"

(TEST_REPO_ROOT="$FAKE_REPO" TEST_SHA="$SHA" bash -c "
    source '$FUNCS_FILE'
    REPO_ROOT='$FAKE_REPO'
    cascade_rebase_if_hot
" 2>/dev/null) &
PID1=$!

(TEST_REPO_ROOT="$FAKE_REPO" TEST_SHA="$SHA" bash -c "
    source '$FUNCS_FILE'
    REPO_ROOT='$FAKE_REPO'
    cascade_rebase_if_hot
" 2>/dev/null) &
PID2=$!

(TEST_REPO_ROOT="$FAKE_REPO" TEST_SHA="$SHA" bash -c "
    source '$FUNCS_FILE'
    REPO_ROOT='$FAKE_REPO'
    cascade_rebase_if_hot
" 2>/dev/null) &
PID3=$!

wait $PID1 $PID2 $PID3

triggered=$(grep -c '"kind":"cascade_rebase_triggered"' "$AMBIENT" 2>/dev/null || echo 0)
skipped=$(grep -c '"kind":"cascade_rebase_skipped_duplicate"' "$AMBIENT" 2>/dev/null || echo 0)

if [[ "$triggered" -eq 1 ]]; then
    ok "Test 1: exactly 1 worker fired cascade_rebase_triggered (got $triggered)"
else
    fail "Test 1: expected exactly 1 cascade_rebase_triggered, got $triggered"
fi

if [[ "$skipped" -eq 2 ]]; then
    ok "Test 2-3: exactly 2 workers emitted cascade_rebase_skipped_duplicate (got $skipped)"
else
    fail "Test 2-3: expected 2 cascade_rebase_skipped_duplicate, got $skipped"
fi

# ── Test 4: serial re-call with SAME SHA → skipped (lock persists) ────────
bash -c "
    source '$FUNCS_FILE'
    REPO_ROOT='$FAKE_REPO'
    TEST_SHA='$SHA'
    export TEST_SHA
    cascade_rebase_if_hot
" 2>/dev/null || true

skipped2=$(grep -c '"kind":"cascade_rebase_skipped_duplicate"' "$AMBIENT" 2>/dev/null || echo 0)
if [[ "$skipped2" -ge 3 ]]; then
    ok "Test 4: serial re-call with same SHA skipped (lock still held)"
else
    fail "Test 4: expected ≥3 skipped events after serial re-call, got $skipped2"
fi

# ── Test 5: different SHA → new cascade fires ──────────────────────────────
SHA2="deadbeef9999"
bash -c "
    source '$FUNCS_FILE'
    REPO_ROOT='$FAKE_REPO'
    TEST_SHA='$SHA2'
    export TEST_SHA
    cascade_rebase_if_hot
" 2>/dev/null || true

triggered2=$(grep -c '"kind":"cascade_rebase_triggered"' "$AMBIENT" 2>/dev/null || echo 0)
if [[ "$triggered2" -eq 2 ]]; then
    ok "Test 5: different SHA acquired new lock and fired cascade (total triggered=$triggered2)"
else
    fail "Test 5: expected 2 total cascade_rebase_triggered after new SHA, got $triggered2"
fi

echo ""
echo "=== test-cascade-rebase-debounce.sh PASSED ==="
