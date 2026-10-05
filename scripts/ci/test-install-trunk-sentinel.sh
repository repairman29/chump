#!/usr/bin/env bash
# scripts/ci/test-install-trunk-sentinel.sh — INFRA-2338
#
# Smoke test for scripts/setup/install-trunk-sentinel.sh: verifies it writes
# BOTH the trunk-sentinel plist AND the fix-trunk-dispatcher plist, with
# REPO_ROOT correctly substituted (no leftover "REPO_ROOT" placeholder, no
# ephemeral /tmp path baked in — see test-plist-no-tmp-paths.sh for the
# related static gate).
#
# Mocks `launchctl` and `plutil` (both macOS-only, unavailable in Linux CI)
# via a stub bin dir prepended to PATH, and points HOME at a temp dir so the
# real ~/Library/LaunchAgents/ is never touched.
#
# Usage:
#   bash scripts/ci/test-install-trunk-sentinel.sh
#   VERBOSE=1 bash scripts/ci/test-install-trunk-sentinel.sh

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
INSTALL_SCRIPT="$REPO_ROOT/scripts/setup/install-trunk-sentinel.sh"
VERBOSE="${VERBOSE:-0}"

PASS=0
FAIL=0

log()  { [[ "$VERBOSE" == "1" ]] && printf '[test-install-trunk-sentinel] %s\n' "$*" >&2 || true; }
pass() { PASS=$(( PASS + 1 )); printf 'PASS  %s\n' "$1"; }
fail() { FAIL=$(( FAIL + 1 )); printf 'FAIL  %s\n' "$1"; }

if [[ ! -f "$INSTALL_SCRIPT" ]]; then
    echo "FATAL: install script not found: $INSTALL_SCRIPT" >&2
    exit 1
fi

# Expected REPO_ROOT the installer will resolve to (main worktree, same
# resolution logic install-trunk-sentinel.sh itself uses).
source "$REPO_ROOT/scripts/lib/resolve-main-worktree.sh"
EXPECT_ROOT="$(resolve_main_worktree "$INSTALL_SCRIPT")"

TMPDIR_WORK="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_WORK"' EXIT

FAKE_HOME="$TMPDIR_WORK/home"
FAKE_BIN="$TMPDIR_WORK/bin"
mkdir -p "$FAKE_HOME" "$FAKE_BIN"

# ── Stub launchctl + plutil (macOS-only binaries) ────────────────────────────
cat > "$FAKE_BIN/launchctl" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
cat > "$FAKE_BIN/plutil" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$FAKE_BIN/launchctl" "$FAKE_BIN/plutil"

log "running installer with FAKE_HOME=$FAKE_HOME"

OUTPUT="$(HOME="$FAKE_HOME" PATH="$FAKE_BIN:$PATH" bash "$INSTALL_SCRIPT" 2>&1)"
RC=$?

if [[ "$RC" -eq 0 ]]; then
    pass "installer exited 0"
else
    fail "installer exited non-zero (rc=$RC): $OUTPUT"
fi

SENTINEL_PLIST="$FAKE_HOME/Library/LaunchAgents/com.chump.trunk-sentinel.plist"
DISPATCHER_PLIST="$FAKE_HOME/Library/LaunchAgents/com.chump.fix-trunk-dispatcher.plist"

# ── Test: both plists written ────────────────────────────────────────────────

if [[ -f "$SENTINEL_PLIST" ]]; then
    pass "sentinel plist written"
else
    fail "sentinel plist missing: $SENTINEL_PLIST"
fi

if [[ -f "$DISPATCHER_PLIST" ]]; then
    pass "dispatcher plist written"
else
    fail "dispatcher plist missing: $DISPATCHER_PLIST"
fi

# ── Test: dispatcher plist has REPO_ROOT correctly substituted ──────────────

if [[ -f "$DISPATCHER_PLIST" ]]; then
    if grep -q "REPO_ROOT" "$DISPATCHER_PLIST"; then
        fail "dispatcher plist still contains literal 'REPO_ROOT' placeholder"
    else
        pass "dispatcher plist has no leftover REPO_ROOT placeholder"
    fi

    if grep -qF "<string>${EXPECT_ROOT}</string>" "$DISPATCHER_PLIST"; then
        pass "dispatcher plist WorkingDirectory substituted with resolved repo root"
    else
        fail "dispatcher plist missing expected WorkingDirectory ${EXPECT_ROOT}"
    fi

    if grep -qF "${EXPECT_ROOT}/scripts/dispatch/fix-trunk-dispatcher.sh" "$DISPATCHER_PLIST"; then
        pass "dispatcher plist ProgramArguments references resolved dispatcher script path"
    else
        fail "dispatcher plist ProgramArguments missing resolved dispatcher script path"
    fi
fi

# ── Test: sentinel plist also uses resolved root (no /tmp baked in) ─────────

if [[ -f "$SENTINEL_PLIST" ]]; then
    if grep -qF "<string>${EXPECT_ROOT}</string>" "$SENTINEL_PLIST"; then
        pass "sentinel plist WorkingDirectory substituted with resolved repo root"
    else
        fail "sentinel plist missing expected WorkingDirectory ${EXPECT_ROOT}"
    fi
fi

# ── Summary ───────────────────────────────────────────────────────────────────

echo ""
echo "[test-install-trunk-sentinel] ${PASS} passed, ${FAIL} failed"

if [[ "$FAIL" -gt 0 ]]; then
    exit 1
fi
exit 0
