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
grep -qF "exec \"$SHIM_SRC\"" "$INSTALL_DIR/gh" \
    || fail "wrapper does not exec the repo shim"
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
python3 -c "import json; json.dump([${NOW}, ${NOW}, ${NOW}], open('$LOCK_DIR/.gh-throttle-window','w'))"
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

echo
echo "All INFRA-1136 install-gh-shim tests passed."
