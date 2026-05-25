#!/usr/bin/env bash
# test-jit-binary-refresh.sh — INFRA-1977 (H8) structural regression test.
#
# Verifies the JIT binary-refresh mechanism is wired into the staleness
# gate at src/version.rs:fail_if_stale_for_destructive:
#   - trigger_or_check_binary_refresh function exists
#   - reads/writes .chump/binary-refresh-state.json marker
#   - emits binary_refresh_started/completed/failed ambient events
#   - CHUMP_DISABLE_JIT_BINARY_REFRESH=1 escape hatch present
#   - in-flight rebuilds older than 10min are treated as stuck (reap-retry)
#   - failed rebuilds younger than 60s respected (no thrash)
#   - "Recently completed" branch tells operator to retry from fresh shell
#   - All 3 new event kinds are in EVENT_REGISTRY.yaml
#
# This is a STRUCTURAL test — runtime behavior validation is a follow-up
# (best as a Rust unit test in src/version.rs with a mock filesystem).

set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
cd "$REPO_ROOT"

fail() { echo "[FAIL] $1" >&2; exit 1; }
pass() { echo "[PASS] $1"; }

SRC="src/version.rs"
REG="docs/observability/EVENT_REGISTRY.yaml"

# ---- 1. JIT refresh function exists ----
grep -q 'fn trigger_or_check_binary_refresh' "$SRC" \
    || fail "missing trigger_or_check_binary_refresh"
pass "trigger_or_check_binary_refresh present"

# ---- 2. State-file marker path ----
grep -q 'binary-refresh-state.json' "$SRC" \
    || fail "missing .chump/binary-refresh-state.json marker"
pass ".chump/binary-refresh-state.json marker path present"

# ---- 3. Background rebuild spawn ----
grep -q 'fn spawn_background_rebuild' "$SRC" \
    || fail "missing spawn_background_rebuild"
grep -q 'cargo install --path' "$SRC" \
    || fail "missing cargo install command in background rebuild"
pass "spawn_background_rebuild calls cargo install --path"

# ---- 4. Three new event kinds emitted ----
grep -q 'binary_refresh_started' "$SRC" \
    || fail "missing binary_refresh_started emit"
grep -q 'binary_refresh_completed' "$SRC" \
    || fail "missing binary_refresh_completed emit"
grep -q 'binary_refresh_failed' "$SRC" \
    || fail "missing binary_refresh_failed emit"
pass "all 3 event kinds emitted from src/version.rs"

# ---- 5. Escape hatch CHUMP_DISABLE_JIT_BINARY_REFRESH ----
grep -q 'CHUMP_DISABLE_JIT_BINARY_REFRESH' "$SRC" \
    || fail "missing CHUMP_DISABLE_JIT_BINARY_REFRESH escape hatch"
pass "CHUMP_DISABLE_JIT_BINARY_REFRESH escape hatch present"

# ---- 6. In-flight stuck-rebuild detection (>600s = 10min reap) ----
grep -qE '600|10[[:space:]]*\*[[:space:]]*60' "$SRC" \
    || fail "missing 10-minute stuck-rebuild reap threshold"
pass "stuck-rebuild reap (>10min) logic present"

# ---- 7. Failed-rebuild thrash protection (<60s no-retry) ----
if grep -B5 -A15 'BinaryRefreshState::Failed' "$SRC" | grep -qE 'age < 60|< 60_'; then
    pass "failed-rebuild thrash protection (60s) present"
else
    fail "missing 60s thrash protection on failed rebuilds"
fi

# ---- 8. RecentlyCompleted branch with operator hint ----
grep -q 'RecentlyCompleted' "$SRC" \
    || fail "missing RecentlyCompleted refresh state"
grep -qE 'fresh invocation|close this shell' "$SRC" \
    || fail "missing operator hint about fresh shell invocation"
pass "RecentlyCompleted branch with operator hint present"

# ---- 9. All 3 new kinds registered in EVENT_REGISTRY.yaml ----
for kind in binary_refresh_started binary_refresh_completed binary_refresh_failed; do
    grep -q "kind: $kind" "$REG" \
        || fail "EVENT_REGISTRY.yaml missing kind: $kind"
done
pass "EVENT_REGISTRY.yaml has all 3 new kinds"

# ---- 10. Override message preserved (still mentions CHUMP_ALLOW_STALE_DESTRUCTIVE) ----
grep -q 'CHUMP_ALLOW_STALE_DESTRUCTIVE=1' "$SRC" \
    || fail "missing CHUMP_ALLOW_STALE_DESTRUCTIVE escape hatch reference"
pass "operator override path preserved"

echo
echo "[OK] all 10 INFRA-1977 structural cases passed"
