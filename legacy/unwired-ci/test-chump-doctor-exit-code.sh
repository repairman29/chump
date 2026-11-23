#!/usr/bin/env bash
# test-chump-doctor-exit-code.sh — INFRA-585
# Verifies chump-binary-unwedge.sh exits 0 when the binary is healthy (no zombies),
# and exits non-zero when the probe times out (wedged binary).
# This catches the false-positive WARN regression: grep returning 1 in
# reap_zombies() with set -euo pipefail was masking a clean probe as failure.
set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
DOCTOR="$REPO_ROOT/scripts/dev/chump-binary-unwedge.sh"
pass() { printf 'PASS: %s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

[[ -x "$DOCTOR" ]] || fail "chump-binary-unwedge.sh missing or not executable"

TMPDIR_BASE=$(mktemp -d -t test-chump-doctor-exit-code-XXXXXX)
trap 'rm -rf "$TMPDIR_BASE"' EXIT

# ── Test 1: healthy binary → exit 0 ──────────────────────────────────────────
# Stub a fast "healthy" chump binary that exits 0 immediately.
FAKE_BIN="$TMPDIR_BASE/chump"
cat > "$FAKE_BIN" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$FAKE_BIN"

exit_code=0
CHUMP_DOCTOR_QUIET=1 PATH="$TMPDIR_BASE:$PATH" bash "$DOCTOR" >/dev/null 2>&1 || exit_code=$?
if [[ "$exit_code" -eq 0 ]]; then
    pass "healthy binary → exit 0"
else
    fail "healthy binary returned exit $exit_code (false-positive WARN regression)"
fi

# ── Test 2: healthy binary with no UE zombies → still exit 0 ─────────────────
# Reap path must not fail when grep finds no matching zombies (the INFRA-585 bug).
exit_code=0
CHUMP_DOCTOR_QUIET=1 PATH="$TMPDIR_BASE:$PATH" bash "$DOCTOR" >/dev/null 2>&1 || exit_code=$?
if [[ "$exit_code" -eq 0 ]]; then
    pass "no UE zombies → reap_zombies grep returns 1 but exit still 0"
else
    fail "reap_zombies grep-no-match caused exit $exit_code (INFRA-585 false-positive)"
fi

# ── Test 3: wedged binary (slow) → exit non-zero ─────────────────────────────
FAKE_BIN_SLOW="$TMPDIR_BASE/chump"
cat > "$FAKE_BIN_SLOW" <<'EOF'
#!/usr/bin/env bash
sleep 30
EOF
chmod +x "$FAKE_BIN_SLOW"

exit_code=0
CHUMP_DOCTOR_QUIET=1 CHUMP_DOCTOR_TIMEOUT=1 PATH="$TMPDIR_BASE:$PATH" bash "$DOCTOR" >/dev/null 2>&1 || exit_code=$?
if [[ "$exit_code" -ne 0 ]]; then
    pass "wedged binary (slow) → exit non-zero"
else
    fail "wedged binary returned exit 0 (should have been non-zero)"
fi

echo "PASS: test-chump-doctor-exit-code (INFRA-585)"
