#!/usr/bin/env bash
# scripts/ci/test-ambient-rotation.sh — INFRA-1468
#
# Validates that ambient.jsonl rotation fires automatically when the file
# exceeds CHUMP_AMBIENT_MAX_MB, and that scripts/ops/ambient-rotate-now.sh
# performs a force-rotate correctly.
#
# Tests:
#   1. Below threshold: no rotation, no lagging event
#   2. Above threshold: kind=ambient_rotation_lagging emitted + file rotated (.1 created)
#   3. Force-rotate script: rotates regardless of size, writes ambient_rotated event
#   4. Dry-run flag: no mutations occur
#   5. Rotate keeps .2 pruned (3-slot cascade)

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

CHUMP_BIN="${CHUMP_BIN:-$(cd "$REPO_ROOT" && cargo build --bin chump -q 2>/dev/null && echo "${CARGO_TARGET_DIR:-$REPO_ROOT/target}/debug/chump")}"
if [[ ! -x "$CHUMP_BIN" ]]; then
    echo "SKIP: chump binary not found at $CHUMP_BIN"
    exit 0
fi

PASS=0; FAIL=0; FAILS=()
ok()   { printf '\033[0;32mPASS\033[0m %s\n' "$*"; PASS=$((PASS+1)); }
fail() { printf '\033[0;31mFAIL\033[0m %s\n' "$*"; FAIL=$((FAIL+1)); FAILS+=("$*"); }

TMP="$(mktemp -d)"

# W-013 immunization (RESILIENT-024): unset workflow-injected env so this
# tests own $TMP fixtures are not hijacked by CI workflow CHUMP_LOCK_DIR.
unset CHUMP_REPO CHUMP_LOCK_DIR
trap 'rm -rf "$TMP"' EXIT

AMBIENT="$TMP/ambient.jsonl"

echo "=== INFRA-1468 ambient rotation tests ==="

# ── Test 1: below threshold — no rotation ─────────────────────────────────────
echo
echo "[1. Below threshold: no rotation, no lagging event]"

printf '{"ts":"2026-01-01T00:00:00Z","kind":"heartbeat"}\n' > "$AMBIENT"

CHUMP_AMBIENT_LOG="$AMBIENT" CHUMP_AMBIENT_MAX_MB=50 \
    "$CHUMP_BIN" ambient emit test_below_threshold 2>/dev/null

if [[ -f "$AMBIENT" ]]; then
    ok "ambient.jsonl still present after emit below threshold"
else
    fail "ambient.jsonl was removed (unexpected rotation)"
fi

if [[ ! -f "${AMBIENT}.1" ]]; then
    ok "no .1 archive created (below threshold)"
else
    fail ".1 archive created unexpectedly below threshold"
fi

if grep -q "ambient_rotation_lagging" "$AMBIENT" 2>/dev/null; then
    fail "ambient_rotation_lagging emitted below threshold (should not)"
else
    ok "no ambient_rotation_lagging below threshold"
fi

# ── Test 2: above threshold — lagging event + rotation ────────────────────────
echo
echo "[2. Above threshold: lagging event emitted + file rotated]"

# Seed a file that's just over 1 MB
dd if=/dev/zero bs=1024 count=1025 2>/dev/null | tr '\0' 'x' > "$AMBIENT"
SEEDED_SIZE="$(wc -c < "$AMBIENT")"

CHUMP_AMBIENT_LOG="$AMBIENT" CHUMP_AMBIENT_MAX_MB=1 \
    "$CHUMP_BIN" ambient emit test_above_threshold 2>/dev/null

if [[ -f "${AMBIENT}.1" ]]; then
    ok "ambient.jsonl.1 created (rotation fired)"
else
    fail "ambient.jsonl.1 NOT created — rotation did not fire"
fi

# The lagging event should be in the archive (.1) since it's written before rename
if grep -q "ambient_rotation_lagging" "${AMBIENT}.1" 2>/dev/null; then
    ok "kind=ambient_rotation_lagging found in archive (.1)"
else
    fail "kind=ambient_rotation_lagging NOT in archive — watchdog did not fire"
fi

# The fresh ambient.jsonl should exist and be small
if [[ -f "$AMBIENT" ]]; then
    FRESH_SIZE="$(wc -c < "$AMBIENT")"
    if [[ "$FRESH_SIZE" -lt 10000 ]]; then
        ok "fresh ambient.jsonl is small (${FRESH_SIZE} bytes) — rotation worked"
    else
        fail "fresh ambient.jsonl is unexpectedly large (${FRESH_SIZE} bytes)"
    fi
else
    # File may not exist yet if no subsequent append created it; also OK
    ok "ambient.jsonl absent before next append (fresh start)"
fi

# Verify size_bytes field in the lagging event is reasonable
LAGGING_SIZE=$(grep "ambient_rotation_lagging" "${AMBIENT}.1" 2>/dev/null | \
    python3 -c "import json,sys; d=json.loads(sys.stdin.read().strip()); print(d.get('size_bytes',0))" 2>/dev/null || echo 0)
if [[ "$LAGGING_SIZE" -ge "$SEEDED_SIZE" ]]; then
    ok "lagging event size_bytes=$LAGGING_SIZE >= seeded $SEEDED_SIZE"
else
    fail "lagging event size_bytes=$LAGGING_SIZE < seeded $SEEDED_SIZE (wrong size reported)"
fi

# ── Test 3: ambient-rotate-now.sh force-rotate ────────────────────────────────
echo
echo "[3. ambient-rotate-now.sh force-rotate (small file)]"

SCRIPT="$REPO_ROOT/scripts/ops/ambient-rotate-now.sh"
if [[ ! -x "$SCRIPT" ]]; then
    fail "scripts/ops/ambient-rotate-now.sh not found or not executable"
else
    ok "ambient-rotate-now.sh exists and is executable"
fi

# Reset state
rm -f "${AMBIENT}.1" "${AMBIENT}.2"
printf '{"ts":"2026-01-01T00:00:00Z","kind":"small"}\n' > "$AMBIENT"

CHUMP_AMBIENT_LOG="$AMBIENT" bash "$SCRIPT" 2>/dev/null

if [[ -f "${AMBIENT}.1" ]]; then
    ok "force-rotate created .1 even for small file"
else
    fail "force-rotate did NOT create .1"
fi

if grep -q "ambient_rotated" "$AMBIENT" 2>/dev/null; then
    ok "fresh ambient.jsonl contains kind=ambient_rotated summary"
else
    fail "fresh ambient.jsonl missing kind=ambient_rotated summary"
fi

# ── Test 4: dry-run mode — no mutations ───────────────────────────────────────
echo
echo "[4. dry-run flag: no mutations]"

rm -f "${AMBIENT}.1" "${AMBIENT}.2"
printf '{"ts":"2026-01-01T00:00:00Z","kind":"sentinel"}\n' > "$AMBIENT"
SNAP="$(md5sum "$AMBIENT" | awk '{print $1}')"

CHUMP_AMBIENT_LOG="$AMBIENT" bash "$SCRIPT" --dry-run 2>/dev/null

SNAP2="$(md5sum "$AMBIENT" | awk '{print $1}')"
if [[ "$SNAP" == "$SNAP2" ]]; then
    ok "dry-run: ambient.jsonl unchanged"
else
    fail "dry-run: ambient.jsonl was modified"
fi

if [[ ! -f "${AMBIENT}.1" ]]; then
    ok "dry-run: no .1 archive created"
else
    fail "dry-run: .1 archive was created (should not)"
fi

# ── Test 5: cascade — .2 pruned on second rotation ────────────────────────────
echo
echo "[5. cascade: .2 pruned on second rotation]"

rm -f "${AMBIENT}" "${AMBIENT}.1" "${AMBIENT}.2"
printf 'slot1-data\n' > "${AMBIENT}.1"
printf 'slot2-sentinel\n' > "${AMBIENT}.2"
printf '{"ts":"2026-01-01T00:00:00Z","kind":"x"}\n' > "$AMBIENT"

CHUMP_AMBIENT_LOG="$AMBIENT" bash "$SCRIPT" 2>/dev/null

if [[ -f "${AMBIENT}.2" ]]; then
    CONTENT="$(cat "${AMBIENT}.2" 2>/dev/null)"
    if echo "$CONTENT" | grep -q "slot2-sentinel"; then
        fail "old sentinel in .2 still present — cascade failed"
    else
        ok ".2 updated (old sentinel replaced by former .1)"
    fi
else
    ok ".2 absent (old sentinel pruned)"
fi

# ── Results ───────────────────────────────────────────────────────────────────
echo
echo "=== Results: $PASS passed, $FAIL failed ==="
if (( FAIL > 0 )); then
    for f in "${FAILS[@]}"; do printf '  ✗ %s\n' "$f"; done
    exit 1
fi
echo "PASS"
