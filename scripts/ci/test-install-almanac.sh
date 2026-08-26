#!/usr/bin/env bash
# test-install-almanac.sh — RESILIENT-403
#
# Proves scripts/setup/install-almanac.sh:
#   1. clones almanac from scratch when no checkout exists
#   2. builds it and installs both `almanac` and `almanac-mcp` binaries
#   3. wires CHUMP_ALMANAC_MCP_BIN into the chump config env file
#   4. --check reports complete after a fresh install
#   5. re-running is idempotent: no duplicate CHUMP_ALMANAC_MCP_BIN lines,
#      no duplicate rc-file blocks
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
SCRIPT="$PWD/scripts/setup/install-almanac.sh"

TMP="$(mktemp -d -t install-almanac-test.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

PASS=0
FAIL=0
ok()   { printf 'PASS: %s\n' "$*"; PASS=$((PASS+1)); }
fail() { printf 'FAIL: %s\n' "$*"; FAIL=$((FAIL+1)); }

# --- fake origin + source checkout (like a real repairman29/almanac) ---
ORIGIN="$TMP/almanac-origin.git"
SRC="$TMP/almanac-src"
git init --quiet --bare "$ORIGIN"
git init --quiet "$SRC"
git -C "$SRC" config user.email "test@example.com"
git -C "$SRC" config user.name "Test"
cat > "$SRC/Cargo.toml" <<'EOF'
[package]
name = "almanac"
version = "0.1.0"
EOF
echo "placeholder" > "$SRC/README.md"
git -C "$SRC" add -A
git -C "$SRC" commit --quiet -m "init"
git -C "$SRC" branch -M main
git -C "$SRC" remote add origin "$ORIGIN"
git -C "$SRC" push --quiet origin main

REPO="$TMP/almanac"
INSTALL_DIR="$TMP/install"
ENV_FILE="$TMP/chump-env"
RC_FILE="$TMP/fake-rc"
touch "$RC_FILE"

BUILD_LOG="$TMP/build-calls.log"
FAKE_BUILD="echo ran >> '$BUILD_LOG'; mkdir -p '$REPO/target/release'; \
printf '#!/bin/sh\necho fake-almanac\n' > '$REPO/target/release/almanac'; \
printf '#!/bin/sh\necho fake-almanac-mcp\n' > '$REPO/target/release/almanac-mcp'; \
chmod +x '$REPO/target/release/almanac' '$REPO/target/release/almanac-mcp'"

run_install() {
    CHUMP_ALMANAC_REPO="$REPO" \
    ALMANAC_CLONE_URL="$ORIGIN" \
    ALMANAC_BUILD_CMD="$FAKE_BUILD" \
    ALMANAC_INSTALL_DIR="$INSTALL_DIR" \
    CHUMP_ENV_FILE="$ENV_FILE" \
    CHUMP_ALMANAC_RC_FILES="$RC_FILE" \
    CHUMP_REPO_ROOT="$TMP" \
    bash "$SCRIPT" "$@"
}

echo "=== install-almanac.sh test ==="
echo

# ── Test 1: fresh install clones, builds, installs, wires config ────────────
if run_install >"$TMP/install1.log" 2>&1; then
    ok "fresh install exits 0"
else
    fail "fresh install failed"
    cat "$TMP/install1.log"
fi

if [[ -d "$REPO/.git" ]]; then
    ok "almanac cloned to $REPO"
else
    fail "almanac was not cloned"
fi

if [[ -x "$INSTALL_DIR/almanac" && -x "$INSTALL_DIR/almanac-mcp" ]]; then
    ok "both almanac and almanac-mcp binaries installed"
else
    fail "binaries not installed at $INSTALL_DIR"
fi

if grep -q "^CHUMP_ALMANAC_MCP_BIN=$INSTALL_DIR/almanac-mcp\$" "$ENV_FILE"; then
    ok "CHUMP_ALMANAC_MCP_BIN wired into $ENV_FILE"
else
    fail "CHUMP_ALMANAC_MCP_BIN not correctly wired into $ENV_FILE"
fi

if grep -q "chump env (RESILIENT-403" "$RC_FILE"; then
    ok "rc file sources the chump env file"
else
    fail "rc file was not wired to source the chump env file"
fi

# ── Test 2: --check reports success after install ───────────────────────────
if run_install --check >"$TMP/check1.log" 2>&1; then
    ok "--check passes after a fresh install"
else
    fail "--check failed after a fresh install"
    cat "$TMP/check1.log"
fi

# ── Test 3: idempotent re-run — no duplicate lines ───────────────────────────
run_install >"$TMP/install2.log" 2>&1
run_install >"$TMP/install3.log" 2>&1

ENV_HITS="$(grep -c "^CHUMP_ALMANAC_MCP_BIN=" "$ENV_FILE" || true)"
if [[ "$ENV_HITS" -eq 1 ]]; then
    ok "re-running does not duplicate CHUMP_ALMANAC_MCP_BIN in $ENV_FILE"
else
    fail "expected exactly 1 CHUMP_ALMANAC_MCP_BIN line, found $ENV_HITS"
fi

RC_HITS="$(grep -c "chump env (RESILIENT-403" "$RC_FILE" || true)"
if [[ "$RC_HITS" -eq 1 ]]; then
    ok "re-running does not duplicate the rc-file source block"
else
    fail "expected exactly 1 rc-file source block, found $RC_HITS"
fi

BUILD_CALLS="$(wc -l < "$BUILD_LOG" | tr -d ' ')"
if [[ "$BUILD_CALLS" -eq 3 ]]; then
    ok "build ran once per install invocation (3 installs = 3 build calls)"
else
    fail "expected 3 build calls across 3 install runs, saw $BUILD_CALLS"
fi

# ── Test 4: missing repo, no clone URL reachable → clean failure, not a crash ─
BAD_REPO="$TMP/nonexistent-almanac"
if CHUMP_ALMANAC_REPO="$BAD_REPO" \
   ALMANAC_CLONE_URL="$TMP/does-not-exist.git" \
   ALMANAC_INSTALL_DIR="$TMP/install-bad" \
   CHUMP_ENV_FILE="$TMP/chump-env-bad" \
   CHUMP_ALMANAC_RC_FILES="$TMP/fake-rc-bad" \
   CHUMP_REPO_ROOT="$TMP" \
   bash "$SCRIPT" >"$TMP/badclone.log" 2>&1; then
    fail "install should have failed with an unreachable clone URL"
else
    ok "unreachable clone URL fails cleanly (non-zero exit, no crash)"
fi

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
