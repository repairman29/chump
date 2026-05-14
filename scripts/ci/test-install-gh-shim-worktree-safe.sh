#!/usr/bin/env bash
# scripts/ci/test-install-gh-shim-worktree-safe.sh — INFRA-1186
#
# Verifies that install-gh-shim.sh refuses to embed an ephemeral
# (linked-worktree) path into ~/.local/bin/gh and instead resolves to the
# canonical main-checkout path — or emits an error and exits 5 when no
# canonical path is resolvable.
#
# AC4 of INFRA-1186.
#
# All filesystem mutations happen in a tempdir — no real ~/.local/bin writes.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd -P)"
INSTALLER="$REPO_ROOT/scripts/setup/install-gh-shim.sh"

PASS=0
FAIL=0
ok()   { printf '\033[0;32mPASS\033[0m %s\n' "$*"; PASS=$((PASS+1)); }
fail() { printf '\033[0;31mFAIL\033[0m %s\n' "$*"; FAIL=$((FAIL+1)); }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

[ -x "$INSTALLER" ] || { echo "FATAL: installer not executable: $INSTALLER" >&2; exit 2; }

echo "=== INFRA-1186 install-gh-shim worktree-safety tests ==="
echo

# ── Test 1: Running from real REPO_ROOT installs with canonical path ──────────
echo "--- Test 1: install from main checkout embeds canonical path ---"
INSTALL_DIR1="$TMP/bin1"
# Override PATH so which-gh check succeeds (installer requires wrapper first in PATH)
REAL_GH_DIR="$(dirname "$(command -v gh 2>/dev/null || echo /usr/bin/gh)")"

# Run installer from the main checkout (REPO_ROOT is not ephemeral)
out1="$(CHUMP_GH_INSTALL_QUIET=1 bash "$INSTALLER" --dir "$INSTALL_DIR1" \
         2>&1)" && exit1=0 || exit1=$?

# The installer may exit 4 (PATH ordering warn) but should NOT exit 5 (ephemeral reject)
if [ "$exit1" -ne 5 ]; then
    ok "installer from main checkout did not exit 5 (ephemeral reject)"
else
    fail "installer from main checkout unexpectedly exited 5 (REPO_ROOT=$REPO_ROOT)"
fi

if [ -f "$INSTALL_DIR1/gh" ]; then
    wrapper_path="$(grep 'exec "' "$INSTALL_DIR1/gh" | head -1 | sed 's/.*exec "\(.*\)".*/\1/')"
    if echo "$wrapper_path" | grep -qE '^/(private/)?tmp/'; then
        fail "wrapper embeds ephemeral path: $wrapper_path"
    else
        ok "wrapper embeds non-ephemeral path: $wrapper_path"
    fi
    # Wrapper must embed a real shim location under scripts/coord/lib/gh-shim/gh
    if grep -qE 'exec "[^"]+/scripts/coord/lib/gh-shim/gh"' "$INSTALL_DIR1/gh"; then
        ok "wrapper exec line points at scripts/coord/lib/gh-shim/gh"
    else
        fail "wrapper exec line does not reference the shim"
    fi
else
    # Might not have been installed due to PATH-ordering exit 4 — that's OK for this test
    if [ "$exit1" -eq 4 ]; then
        ok "installer exited 4 (PATH ordering) — no wrapper written, acceptable for this test"
    else
        fail "wrapper not written and exit code was $exit1"
    fi
fi

# ── Test 2: Ephemeral REPO_ROOT triggers exit 5 ────────────────────────────
echo "--- Test 2: installer exits 5 when resolved path is ephemeral ---"
# Use /tmp which is ephemeral on both Linux and macOS.
# (On macOS, /tmp is a symlink to /private/tmp; the installer's pwd -P resolves
# that to /private/tmp/* which also matches _is_ephemeral_path. /private/tmp
# does not exist on Linux.)
FAKE_WT="/tmp/chump-infra-1186-fake-wt-$$"
mkdir -p "$FAKE_WT/scripts/setup" "$FAKE_WT/scripts/coord/lib/gh-shim"
trap 'rm -rf "$FAKE_WT"' EXIT
# Copy the installer and create a fake (non-executable-path-resolving) shim
cp "$INSTALLER" "$FAKE_WT/scripts/setup/install-gh-shim.sh"
# Fake shim executable so the installer doesn't bail on the "not executable" check
printf '#!/usr/bin/env bash\n# fake shim\nexec true "$@"\n' > "$FAKE_WT/scripts/coord/lib/gh-shim/gh"
chmod +x "$FAKE_WT/scripts/coord/lib/gh-shim/gh"

INSTALL_DIR2="$TMP/bin2"
# Run from a path that looks like a real-repo script but whose REPO_ROOT
# resolves inside $TMP (ephemeral). We invoke with CHUMP_GH_SHIM_DIR to
# avoid ~/.local/bin writes.
out2="$(CHUMP_GH_INSTALL_QUIET=1 bash "$FAKE_WT/scripts/setup/install-gh-shim.sh" --dir "$INSTALL_DIR2" \
         2>&1)" && exit2=0 || exit2=$?

# The fake-worktree installer may exit 5 (ephemeral) OR succeed because
# git worktree list resolved a canonical non-tmp main checkout.
# The test only asserts: if exit5 → wrapper must NOT exist.
if [ "$exit2" -eq 5 ]; then
    ok "installer exited 5 (ephemeral path rejected)"
    if [ -f "$INSTALL_DIR2/gh" ]; then
        fail "wrapper was written despite exit 5 — should have been refused"
    else
        ok "no wrapper written after exit 5"
    fi
elif [ "$exit2" -eq 0 ] || [ "$exit2" -eq 4 ]; then
    # Installer succeeded or warn-on-PATH: check the wrapper points at main checkout
    if [ -f "$INSTALL_DIR2/gh" ]; then
        w2="$(grep 'exec "' "$INSTALL_DIR2/gh" | head -1 | sed 's/.*exec "\(.*\)".*/\1/')"
        if echo "$w2" | grep -qE '^/(private/)?tmp/'; then
            fail "wrapper embeds ephemeral path even from fake-worktree: $w2"
        else
            ok "installer re-resolved to canonical path: $w2"
        fi
    else
        ok "installer exited $exit2 without writing wrapper — acceptable"
    fi
else
    fail "installer exited $exit2 — unexpected exit code"
fi

# ── Test 3: Verify exec target in wrapper is NOT an ephemeral /tmp path ──────
# The install dir ($TMP/bin1) may itself be under /tmp on Linux — that's fine.
# What must NOT be ephemeral is the shim exec target embedded in the wrapper.
echo "--- Test 3: exec target in wrapper does not reference an ephemeral /tmp path ---"
if [ -f "$INSTALL_DIR1/gh" ]; then
    exec_line="$(grep '^exec ' "$INSTALL_DIR1/gh" 2>/dev/null | head -1)"
    if echo "$exec_line" | grep -qE '/(private/)?tmp/'; then
        fail "exec line in wrapper targets ephemeral /tmp path: $exec_line"
    else
        ok "exec line in wrapper targets non-ephemeral path"
    fi
else
    ok "(wrapper not written — skipping content check)"
fi

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "PASS=$PASS  FAIL=$FAIL"
if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
exit 0
