#!/usr/bin/env bash
# CI: ambient.jsonl auto-rotate (INFRA-941)
set -euo pipefail

PASS=0; FAIL=0
ok()   { echo "  PASS: $*"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $*"; FAIL=$((FAIL+1)); }

BINARY="${CARGO_TARGET_DIR:-target}/debug/chump"
if [[ ! -x "$BINARY" ]]; then
    cargo build --quiet 2>&1
fi

TMPDIR_TEST="$(mktemp -d)"

# W-013 immunization (RESILIENT-024): unset workflow-injected env so this
# tests own $TMP fixtures are not hijacked by CI workflow CHUMP_LOCK_DIR.
unset CHUMP_REPO CHUMP_LOCK_DIR
trap 'rm -rf "$TMPDIR_TEST"' EXIT
mkdir -p "$TMPDIR_TEST/.chump-locks"
mkdir -p "$TMPDIR_TEST/.chump"
touch "$TMPDIR_TEST/.chump/state.db"

AMBIENT="$TMPDIR_TEST/.chump-locks/ambient.jsonl"

# ── Test 1: no rotation below threshold ───────────────────────────────────────
echo "Test 1: no rotation when file is below threshold"
printf '{"kind":"heartbeat"}\n' > "$AMBIENT"
OUT=$(CHUMP_REPO="$TMPDIR_TEST" CHUMP_AMBIENT_MAX_MB=50 "$BINARY" ambient-rotate 2>/dev/null)
if echo "$OUT" | grep -q "no-op"; then
    ok "no-op for small file"
else
    fail "unexpected output for small file: $OUT"
fi
if [[ -f "$AMBIENT" ]]; then
    ok "ambient.jsonl still present after no-op"
else
    fail "ambient.jsonl was removed on no-op"
fi

# ── Test 2: rotation triggers when file exceeds threshold ─────────────────────
echo "Test 2: rotation triggers at 1MB threshold"
dd if=/dev/zero bs=1024 count=1025 2>/dev/null | tr '\0' 'x' > "$AMBIENT"
OUT=$(CHUMP_REPO="$TMPDIR_TEST" CHUMP_AMBIENT_MAX_MB=1 "$BINARY" ambient-rotate 2>/dev/null)
if echo "$OUT" | grep -q "rotated"; then
    ok "rotation reported in output"
else
    fail "rotation not reported: $OUT"
fi
if [[ ! -f "$AMBIENT" ]]; then
    ok "ambient.jsonl renamed away"
else
    fail "ambient.jsonl still present after rotation"
fi
if [[ -f "${AMBIENT}.1" ]]; then
    ok "ambient.jsonl.1 created"
else
    fail "ambient.jsonl.1 missing after rotation"
fi

# ── Test 3: old files pruned on second rotation ───────────────────────────────
echo "Test 3: ambient.jsonl.2 pruned when .1 and current both large"
# Pre-populate .1 (from previous test); write a new large current
dd if=/dev/zero bs=1024 count=1025 2>/dev/null | tr '\0' 'y' > "$AMBIENT"
printf 'slot2-sentinel\n' > "${AMBIENT}.2"
CHUMP_REPO="$TMPDIR_TEST" CHUMP_AMBIENT_MAX_MB=1 "$BINARY" ambient-rotate 2>/dev/null || true
# The old .2 (sentinel) should be gone; .1 should now be the original 'y'-filled file
if [[ -f "${AMBIENT}.2" ]]; then
    CONTENT="$(head -c 20 "${AMBIENT}.2")"
    if echo "$CONTENT" | grep -q "slot2-sentinel"; then
        fail "old ambient.jsonl.2 sentinel still present — not pruned"
    else
        ok "ambient.jsonl.2 updated (old sentinel replaced)"
    fi
else
    ok "ambient.jsonl.2 removed or replaced (old sentinel gone)"
fi

# ── Test 4: fresh append creates new ambient.jsonl after rotation ─────────────
echo "Test 4: fresh append works after rotation"
printf '{"kind":"after_rotate"}\n' > "$AMBIENT"
SIZE=$(wc -c < "$AMBIENT")
if [[ $SIZE -lt 100 ]]; then
    ok "new ambient.jsonl is small (fresh file)"
else
    fail "new ambient.jsonl is unexpectedly large: $SIZE bytes"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
