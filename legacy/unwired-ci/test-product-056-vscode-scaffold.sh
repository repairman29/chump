#!/usr/bin/env bash
# test-product-056-vscode-scaffold.sh — PRODUCT-056 tests.
#
# Verifies VS Code extension scaffold for chump --acp backend (slice 1):
#   (1) extension directory exists at extensions/vscode-chump/
#   (2) package.json has correct name, engines.vscode, main, activationEvents
#   (3) src/extension.ts: activate() defined + AcpClient imported + statusBarItem
#   (4) src/acpClient.ts: AcpClient class + connect() + initialize request
#   (5) tsconfig.json present with outDir and rootDir
#   (6) ACP initialize method used (not a different method name)
#   (7) chump binary path config key present in package.json
#   (8) dispose / deactivate wired (no resource leak on extension deactivation)
#
# Run: ./scripts/ci/test-product-056-vscode-scaffold.sh

set -uo pipefail

PASS=0
FAIL=0
FAILS=()

ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); FAILS+=("$1"); }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
EXT_DIR="$REPO_ROOT/extensions/vscode-chump"
PKG="$EXT_DIR/package.json"
EXT_TS="$EXT_DIR/src/extension.ts"
ACP_TS="$EXT_DIR/src/acpClient.ts"
TSCONFIG="$EXT_DIR/tsconfig.json"

echo "=== PRODUCT-056 VS Code extension scaffold tests ==="
echo

# ── Test 1: extension directory and files present ────────────────────────────
echo "--- Test 1: extension directory exists ---"
if [[ -d "$EXT_DIR" ]] && [[ -f "$PKG" ]] && [[ -f "$EXT_TS" ]] && [[ -f "$ACP_TS" ]]; then
    ok "Test 1: extensions/vscode-chump/ directory + package.json + src/*.ts present"
else
    fail "Test 1: extension directory or key files missing"
fi

# ── Test 2: package.json structure ───────────────────────────────────────────
echo "--- Test 2: package.json has required VS Code extension fields ---"
_pkg_ok=$(python3 - <<PYEOF 2>/dev/null
import json, sys
try:
    pkg = json.load(open("$PKG"))
    assert pkg.get("name") == "vscode-chump", f"name={pkg.get('name')}"
    assert "vscode" in pkg.get("engines", {}), "engines.vscode missing"
    assert pkg.get("main"), "main missing"
    assert pkg.get("activationEvents"), "activationEvents missing"
    assert pkg.get("contributes"), "contributes missing"
    print("ok")
except AssertionError as e:
    print(f"fail: {e}")
except Exception as e:
    print(f"error: {e}")
PYEOF
)
if [[ "$_pkg_ok" == "ok" ]]; then
    ok "Test 2: package.json has name, engines.vscode, main, activationEvents, contributes"
else
    fail "Test 2: package.json missing required fields: $_pkg_ok"
fi

# ── Test 3: extension.ts has activate + AcpClient + statusBarItem ───────────
echo "--- Test 3: extension.ts has activate(), AcpClient, statusBarItem ---"
if grep -q 'export.*function activate\|export async function activate' "$EXT_TS" 2>/dev/null && \
   grep -q 'AcpClient' "$EXT_TS" 2>/dev/null && \
   grep -q 'statusBarItem\|StatusBarItem' "$EXT_TS" 2>/dev/null; then
    ok "Test 3: extension.ts has activate(), AcpClient usage, and statusBarItem"
else
    fail "Test 3: extension.ts missing activate(), AcpClient, or statusBarItem"
fi

# ── Test 4: acpClient.ts has class + connect + initialize ────────────────────
echo "--- Test 4: acpClient.ts has AcpClient class + connect() + initialize ---"
if grep -q 'class AcpClient' "$ACP_TS" 2>/dev/null && \
   grep -q 'async connect' "$ACP_TS" 2>/dev/null && \
   grep -q "'initialize'" "$ACP_TS" 2>/dev/null; then
    ok "Test 4: acpClient.ts has AcpClient class, connect(), and 'initialize' request"
else
    fail "Test 4: acpClient.ts missing AcpClient class, connect(), or 'initialize'"
fi

# ── Test 5: tsconfig.json present with outDir ────────────────────────────────
echo "--- Test 5: tsconfig.json with outDir and rootDir ---"
if grep -q '"outDir"' "$TSCONFIG" 2>/dev/null && \
   grep -q '"rootDir"' "$TSCONFIG" 2>/dev/null; then
    ok "Test 5: tsconfig.json has outDir + rootDir"
else
    fail "Test 5: tsconfig.json missing outDir or rootDir"
fi

# ── Test 6: ACP initialize method (not a custom name) ────────────────────────
echo "--- Test 6: 'initialize' is the ACP method name used ---"
if grep -q "'initialize'" "$ACP_TS" 2>/dev/null || \
   grep -q '"initialize"' "$ACP_TS" 2>/dev/null; then
    ok "Test 6: 'initialize' ACP method name correct in acpClient.ts"
else
    fail "Test 6: 'initialize' method name not found in acpClient.ts"
fi

# ── Test 7: chump.binaryPath config key in package.json ──────────────────────
echo "--- Test 7: chump.binaryPath configuration key in package.json ---"
if grep -q 'chump.binaryPath\|binaryPath' "$PKG" 2>/dev/null; then
    ok "Test 7: chump.binaryPath configuration key present in package.json"
else
    fail "Test 7: chump.binaryPath config key missing from package.json"
fi

# ── Test 8: deactivate + dispose wired ────────────────────────────────────────
echo "--- Test 8: deactivate() and dispose() wired for clean shutdown ---"
if grep -q 'export function deactivate\|export.*deactivate' "$EXT_TS" 2>/dev/null && \
   grep -q 'dispose' "$EXT_TS" 2>/dev/null && \
   grep -q 'dispose' "$ACP_TS" 2>/dev/null; then
    ok "Test 8: deactivate() exported in extension.ts; dispose() in both files"
else
    fail "Test 8: deactivate() or dispose() missing"
fi

# ── Summary ───────────────────────────────────────────────────────────────────
echo
echo "=== Results: $PASS passed, $FAIL failed ==="
if [[ $FAIL -gt 0 ]]; then
    for f in "${FAILS[@]}"; do echo "  - $f"; done
    exit 1
fi
exit 0
