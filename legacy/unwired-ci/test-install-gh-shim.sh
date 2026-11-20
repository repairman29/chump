#!/usr/bin/env bash
# scripts/ci/test-install-gh-shim.sh — INFRA-1136
#
# Verifies install-gh-shim.sh correctly installs the wrapper into a target
# dir, that the wrapper execs the throttled shim, and that interactive-shell
# gh calls now route through the throttle (the abuse vector that INFRA-1103
# alone couldn't close).
#
# All filesystem mutations happen in a tempdir — no real ~/.local/bin writes.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd -P)"
INSTALLER="$REPO_ROOT/scripts/setup/install-gh-shim.sh"
SHIM_SRC="$REPO_ROOT/scripts/coord/lib/gh-shim/gh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

ok()   { printf '\033[0;32mPASS\033[0m %s\n' "$*"; }
fail() { printf '\033[0;31mFAIL\033[0m %s\n' "$*"; exit 1; }

[ -x "$INSTALLER" ] || fail "installer not executable: $INSTALLER"
[ -x "$SHIM_SRC" ]  || fail "shim source not executable: $SHIM_SRC"

# Fake gh that just prints what it would have done, so the wrapper has
# something to exec when PATH is set up.
mkdir -p "$TMP/fakebin"
cat > "$TMP/fakebin/gh" <<'EOF'
#!/usr/bin/env bash
[[ "${1:-}" == "api" && "${2:-}" == "rate_limit" ]] && { echo "4000 4000 0"; exit 0; }
echo "fake-gh: $*"
exit 0
EOF
chmod +x "$TMP/fakebin/gh"

INSTALL_DIR="$TMP/bin"
# Ordering: our install dir BEFORE the fake gh dir.
export PATH="$INSTALL_DIR:$TMP/fakebin:$PATH"

# ── Test 1: install puts a wrapper at $INSTALL_DIR/gh ────────────────────────
bash "$INSTALLER" --dir "$INSTALL_DIR" >/dev/null 2>&1 \
    || fail "installer exited non-zero on clean install"
[ -x "$INSTALL_DIR/gh" ] || fail "wrapper not installed at $INSTALL_DIR/gh"
grep -q 'CHUMP_GH_WRAPPER_VERSION=' "$INSTALL_DIR/gh" \
    || fail "wrapper missing marker line"
# Wrapper must exec SOMETHING that ends in scripts/coord/lib/gh-shim/gh.
# After INFRA-1185 the path resolves to the canonical main-repo location
# (not necessarily $SHIM_SRC if we're running inside a linked worktree).
grep -qE 'exec "[^"]+/scripts/coord/lib/gh-shim/gh"' "$INSTALL_DIR/gh" \
    || fail "wrapper does not exec a path ending in scripts/coord/lib/gh-shim/gh"
ok "install creates wrapper at \$INSTALL_DIR/gh"

# ── Test 2: idempotent — re-run is fine ──────────────────────────────────────
bash "$INSTALLER" --dir "$INSTALL_DIR" >/dev/null 2>&1 \
    || fail "installer failed on re-run"
ok "re-running installer is idempotent"

# ── Test 3: refuses to overwrite a non-chump file ────────────────────────────
mkdir -p "$TMP/foreign-bin"
cat > "$TMP/foreign-bin/gh" <<'EOF'
#!/usr/bin/env bash
echo "not-our-wrapper"
EOF
chmod +x "$TMP/foreign-bin/gh"
if bash "$INSTALLER" --dir "$TMP/foreign-bin" >/dev/null 2>&1; then
    fail "installer should refuse to clobber a non-chump file"
fi
ok "installer refuses to clobber a non-chump gh"

# ── Test 4: the wrapper actually routes through the throttle ────────────────
# Pre-fill window to the limit so the throttle is forced to log.
AMBIENT="$TMP/ambient.jsonl"
LOCK_DIR="$(dirname "$AMBIENT")"
NOW=$(python3 -c "import time;print(time.time())")
python3 -c "import json; json.dump([${NOW}, ${NOW}, ${NOW}], open('$LOCK_DIR/.gh-throttle-window.query','w'))"
# Invoke via PATH lookup (the whole point of the wrapper).
CHUMP_GH_MAX_CALLS_PER_MIN=3 \
CHUMP_AMBIENT_OVERRIDE="$AMBIENT" \
CHUMP_GH_SCRIPT="install-shim-test" \
timeout 4 gh api rate_limit >/dev/null 2>&1 || true
sleep 0.3
[ -f "$AMBIENT" ] || fail "wrapper-routed call produced no ambient event"
grep -q '"kind":"gh_self_throttled"' "$AMBIENT" \
    || fail "wrapper-routed call did NOT fire throttle: $(cat "$AMBIENT")"
ok "wrapper routes interactive \`gh\` through the throttle"

# ── Test 5: --uninstall removes the wrapper ─────────────────────────────────
bash "$INSTALLER" --dir "$INSTALL_DIR" --uninstall >/dev/null 2>&1 \
    || fail "uninstall returned non-zero"
[ ! -e "$INSTALL_DIR/gh" ] || fail "wrapper still present after --uninstall"
ok "--uninstall removes the wrapper"

# ── Test 6: --uninstall leaves foreign files alone ──────────────────────────
bash "$INSTALLER" --dir "$TMP/foreign-bin" --uninstall >/dev/null 2>&1 \
    || fail "uninstall returned non-zero on foreign dir"
[ -f "$TMP/foreign-bin/gh" ] || fail "--uninstall removed a NON-chump gh!"
ok "--uninstall does not touch non-chump files"

# ── Test 7: INFRA-1185 — installer refuses to point at an ephemeral path ─────
# Simulate post-checkout in a linked worktree under /private/tmp: the wrapper
# must NOT end up pointing there, because the worktree disappears after the
# rebase script that triggered the hook removes it.
EPH_REPO="/private/tmp/wt-ephemeral-test-$$"
mkdir -p "$EPH_REPO/scripts/setup" "$EPH_REPO/scripts/coord/lib/gh-shim"
cp "$INSTALLER" "$EPH_REPO/scripts/setup/install-gh-shim.sh"
cp "$SHIM_SRC"  "$EPH_REPO/scripts/coord/lib/gh-shim/gh"
# Run the installer from the ephemeral location.
out=$(bash "$EPH_REPO/scripts/setup/install-gh-shim.sh" --dir "$INSTALL_DIR" 2>&1)
rc=$?
rm -rf "$EPH_REPO"
# Two acceptable outcomes:
#   A) Installer refuses with exit 5 because git couldn't find a non-ephemeral main repo.
#   B) Installer succeeds because `git worktree list --porcelain` resolved to a real
#      non-ephemeral main repo (CI runner case), in which case the wrapper must
#      point at that path, NOT at $EPH_REPO.
if [ "$rc" -eq 5 ]; then
    ok "INFRA-1185: refuses to install from ephemeral path (no main repo resolution available)"
elif [ "$rc" -eq 0 ] && [ -f "$INSTALL_DIR/gh" ]; then
    if grep -qF "$EPH_REPO" "$INSTALL_DIR/gh"; then
        fail "INFRA-1185: wrapper points at ephemeral path $EPH_REPO — would break when worktree is removed"
    fi
    ok "INFRA-1185: from ephemeral path, wrapper resolved to non-ephemeral main repo"
else
    fail "INFRA-1185: unexpected installer behavior rc=$rc out=$out"
fi

# ── Test 8: INFRA-1185 — main-repo invocation still points at main ──────────
# Re-install from the real main checkout; wrapper must NOT have an ephemeral path.
bash "$INSTALLER" --dir "$INSTALL_DIR" >/dev/null 2>&1 \
    || fail "main-repo re-install returned non-zero"
case "$(grep '^exec ' "$INSTALL_DIR/gh")" in
    *'/private/tmp/'*|*'/tmp/'*|*'/var/folders/'*)
        fail "INFRA-1185: main-repo install pointed at ephemeral path"
        ;;
esac
ok "INFRA-1185: main-repo install points at canonical path"

echo
echo "All INFRA-1136/1185 install-gh-shim tests passed."
