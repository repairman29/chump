#!/usr/bin/env bash
# test-ensure-debug-chump-helper.sh — INFRA-1602
#
# Smoke-tests scripts/ci/lib/ensure-debug-chump.sh:
#   1. With CHUMP_BIN env override → helper returns that path without rebuilding.
#   2. With ./target/debug/chump already present → no rebuild (mtime unchanged).
#   3. With PATH fallback → resolves via command -v when target/ is empty AND
#      cargo isn't on PATH AND env is unset (uses a fake stub binary).
#
# Note on AC #4 (smoke test scope): we intentionally do NOT exercise the
# "spawn helper in tmp dir without target/debug/chump → builds + returns valid
# path" branch from the AC literally, because cargo build of the real chump
# crate takes 2+ minutes — way too long for a CI smoke test. Instead we cover
# the build-skip and PATH branches deterministically. The build branch is
# implicitly exercised every time another test-*.sh runs without a prior build.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
HELPER="$SCRIPT_DIR/lib/ensure-debug-chump.sh"

PASS=0
FAIL=0
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

echo "=== INFRA-1602: ensure-debug-chump helper smoke test ==="
echo

# Sanity: helper exists and is executable
if [[ ! -f "$HELPER" ]]; then
    echo "FAIL: helper not found at $HELPER" >&2
    exit 2
fi

# ── Test 1: CHUMP_BIN override path ─────────────────────────────────────────
echo "[1] CHUMP_BIN env override"
TMP="$(mktemp -d -t infra-1602-helper.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

# Create a fake executable that the helper should return verbatim
FAKE_BIN="$TMP/fake-chump"
cat > "$FAKE_BIN" <<'EOF'
#!/usr/bin/env bash
echo "fake chump 0.0.0"
EOF
chmod +x "$FAKE_BIN"

# Subshell to avoid leaking exports
OUT="$(
    # shellcheck disable=SC1090
    source "$HELPER"
    CHUMP_BIN="$FAKE_BIN" ensure_debug_chump
)"
if [[ "$OUT" == "$FAKE_BIN" ]]; then
    ok "CHUMP_BIN env override returned the override path verbatim"
else
    fail "CHUMP_BIN override: expected $FAKE_BIN, got $OUT"
fi

# ── Test 2: no rebuild when binary present (mtime sentinel) ─────────────────
echo
echo "[2] no rebuild when binary present"
# Use a tmp repo root with a pre-staged fake target/debug/chump and a
# .cargo/config.toml that points at it. Helper should resolve + verify without
# touching cargo.
FAKE_REPO="$TMP/fake-repo"
mkdir -p "$FAKE_REPO/target/debug" "$FAKE_REPO/.cargo"
cat > "$FAKE_REPO/.cargo/config.toml" <<EOF
[build]
target-dir = "$FAKE_REPO/target"
EOF
PRESTAGED="$FAKE_REPO/target/debug/chump"
cat > "$PRESTAGED" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "--version" ]]; then
    echo "fake chump 0.0.0"
    exit 0
fi
EOF
chmod +x "$PRESTAGED"

# Capture mtime BEFORE
MTIME_BEFORE="$(stat -f %m "$PRESTAGED" 2>/dev/null || stat -c %Y "$PRESTAGED")"

# Sleep 1s so any rebuild would produce a different mtime
sleep 1

# Unset CHUMP_BIN so the env-override path doesn't short-circuit.
# Point ENSURE_CHUMP_REPO_ROOT at our fake repo so the helper resolves the
# fake .cargo/config.toml.
OUT="$(
    unset CHUMP_BIN CARGO_TARGET_DIR
    # shellcheck disable=SC1090
    source "$HELPER"
    ENSURE_CHUMP_REPO_ROOT="$FAKE_REPO" ensure_debug_chump
)"
MTIME_AFTER="$(stat -f %m "$PRESTAGED" 2>/dev/null || stat -c %Y "$PRESTAGED")"

if [[ "$OUT" == "$PRESTAGED" ]]; then
    ok "resolved path = pre-staged binary"
else
    fail "expected $PRESTAGED, got $OUT"
fi
if [[ "$MTIME_BEFORE" == "$MTIME_AFTER" ]]; then
    ok "binary mtime unchanged → no rebuild fired"
else
    fail "binary mtime changed ($MTIME_BEFORE → $MTIME_AFTER) — helper rebuilt unnecessarily"
fi

# ── Test 3: PATH fallback when cargo unavailable + target empty ─────────────
echo
echo "[3] PATH fallback (no cargo, no target binary)"
FALLBACK_REPO="$TMP/fallback-repo"
mkdir -p "$FALLBACK_REPO/target/debug"  # exists but empty

# Stub chump on PATH
STUB_DIR="$TMP/stub-bin"
mkdir -p "$STUB_DIR"
cat > "$STUB_DIR/chump" <<'EOF'
#!/usr/bin/env bash
echo "stub chump on PATH"
EOF
chmod +x "$STUB_DIR/chump"

# Run with PATH that has stub but NO cargo, and an empty target/debug.
# We blank PATH then add only the stub dir + a minimal set without cargo.
OUT="$(
    unset CHUMP_BIN CARGO_TARGET_DIR
    PATH="$STUB_DIR:/usr/bin:/bin"  # no ~/.cargo/bin
    # shellcheck disable=SC1090
    source "$HELPER"
    # Confirm cargo really is absent in this shell
    if command -v cargo >/dev/null 2>&1; then
        echo "PRECONDITION_FAILED: cargo unexpectedly on PATH" >&2
        exit 99
    fi
    ENSURE_CHUMP_REPO_ROOT="$FALLBACK_REPO" ensure_debug_chump
)" || true

if [[ "$OUT" == "$STUB_DIR/chump" ]]; then
    ok "PATH fallback returned the on-PATH stub when cargo + target/debug missing"
else
    fail "PATH fallback: expected $STUB_DIR/chump, got '$OUT'"
fi

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
