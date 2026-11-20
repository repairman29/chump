#!/usr/bin/env bash
# test-curator-launchd.sh — INFRA-842
#
# Validates the opus-curator and emergency-fast-path launchd plists:
#  - Both plist files exist in launchd/
#  - Labels are correct
#  - StartInterval values: curator=600, fast-path=300
#  - RunAtLoad is false for both
#  - Scripts referenced in ProgramArguments exist
#  - resolve-main-worktree guard present in install script

set -euo pipefail

PASS=0
FAIL=0
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CURATOR_PLIST="$REPO_ROOT/launchd/com.chump.opus-curator.plist"
FASTPATH_PLIST="$REPO_ROOT/launchd/com.chump.emergency-fast-path.plist"
INSTALL_SCRIPT="$REPO_ROOT/scripts/setup/install-curator-launchd.sh"

echo "=== INFRA-842 curator launchd test ==="
echo

# --- plist existence ---
for plist in "$CURATOR_PLIST" "$FASTPATH_PLIST"; do
    name="$(basename "$plist")"
    if [[ -f "$plist" ]]; then
        ok "$name exists"
    else
        fail "$name missing from launchd/"
    fi
done

# --- plist validation via plistlib ---
echo
echo "[plistlib validation]"

CURATOR_INTERVAL="$(python3 - "$CURATOR_PLIST" <<'PY' 2>/dev/null
import sys, plistlib
with open(sys.argv[1], 'rb') as f:
    d = plistlib.load(f)
print(d.get('StartInterval', 0))
PY
)"

FASTPATH_INTERVAL="$(python3 - "$FASTPATH_PLIST" <<'PY' 2>/dev/null
import sys, plistlib
with open(sys.argv[1], 'rb') as f:
    d = plistlib.load(f)
print(d.get('StartInterval', 0))
PY
)"

if [[ "${CURATOR_INTERVAL:-0}" -eq 600 ]]; then
    ok "opus-curator StartInterval=600 (10 min)"
else
    fail "opus-curator StartInterval wrong: got ${CURATOR_INTERVAL:-?} want 600"
fi

if [[ "${FASTPATH_INTERVAL:-0}" -eq 300 ]]; then
    ok "emergency-fast-path StartInterval=300 (5 min)"
else
    fail "emergency-fast-path StartInterval wrong: got ${FASTPATH_INTERVAL:-?} want 300"
fi

CURATOR_LABEL="$(python3 - "$CURATOR_PLIST" <<'PY' 2>/dev/null
import sys, plistlib
with open(sys.argv[1], 'rb') as f:
    d = plistlib.load(f)
print(d.get('Label', ''))
PY
)"

FASTPATH_LABEL="$(python3 - "$FASTPATH_PLIST" <<'PY' 2>/dev/null
import sys, plistlib
with open(sys.argv[1], 'rb') as f:
    d = plistlib.load(f)
print(d.get('Label', ''))
PY
)"

[[ "$CURATOR_LABEL" == "com.chump.opus-curator" ]] \
    && ok "opus-curator Label correct" \
    || fail "opus-curator Label wrong: got '$CURATOR_LABEL'"

[[ "$FASTPATH_LABEL" == "com.chump.emergency-fast-path" ]] \
    && ok "emergency-fast-path Label correct" \
    || fail "emergency-fast-path Label wrong: got '$FASTPATH_LABEL'"

CURATOR_RUNATLOAD="$(python3 - "$CURATOR_PLIST" <<'PY' 2>/dev/null
import sys, plistlib
with open(sys.argv[1], 'rb') as f:
    d = plistlib.load(f)
print(str(d.get('RunAtLoad', True)).lower())
PY
)"

FASTPATH_RUNATLOAD="$(python3 - "$FASTPATH_PLIST" <<'PY' 2>/dev/null
import sys, plistlib
with open(sys.argv[1], 'rb') as f:
    d = plistlib.load(f)
print(str(d.get('RunAtLoad', True)).lower())
PY
)"

[[ "$CURATOR_RUNATLOAD" == "false" ]] \
    && ok "opus-curator RunAtLoad=false" \
    || fail "opus-curator RunAtLoad should be false, got '$CURATOR_RUNATLOAD'"

[[ "$FASTPATH_RUNATLOAD" == "false" ]] \
    && ok "emergency-fast-path RunAtLoad=false" \
    || fail "emergency-fast-path RunAtLoad should be false, got '$FASTPATH_RUNATLOAD'"

# --- scripts referenced exist ---
echo
echo "[script existence]"

if [[ -f "$REPO_ROOT/scripts/coord/opus-curator.sh" ]]; then
    ok "scripts/coord/opus-curator.sh exists"
else
    fail "scripts/coord/opus-curator.sh missing"
fi

if [[ -f "$REPO_ROOT/scripts/coord/emergency-fast-path.sh" ]]; then
    ok "scripts/coord/emergency-fast-path.sh exists"
elif git -C "$REPO_ROOT" show origin/main:scripts/coord/emergency-fast-path.sh >/dev/null 2>&1 \
     || git -C "$REPO_ROOT" show "origin/chump/infra-847-claim:scripts/coord/emergency-fast-path.sh" >/dev/null 2>&1; then
    ok "scripts/coord/emergency-fast-path.sh exists (INFRA-847 pending merge)"
else
    fail "scripts/coord/emergency-fast-path.sh missing (requires INFRA-847)"
fi

# --- install script ---
echo
echo "[install script]"

if [[ -f "$INSTALL_SCRIPT" ]]; then
    ok "scripts/setup/install-curator-launchd.sh exists"
else
    fail "scripts/setup/install-curator-launchd.sh missing"
fi

if grep -q 'resolve-main-worktree' "$INSTALL_SCRIPT" 2>/dev/null; then
    ok "install script uses resolve-main-worktree (INFRA-451)"
else
    fail "install script missing resolve-main-worktree guard"
fi

if grep -q 'launchctl unload' "$INSTALL_SCRIPT" 2>/dev/null; then
    ok "install script unloads before reload (idempotent)"
else
    fail "install script not idempotent (missing unload before load)"
fi

if grep -q 'CHUMP_CURATOR_INTERVAL\|CHUMP_FASTPATH_INTERVAL' "$INSTALL_SCRIPT" 2>/dev/null; then
    ok "install script supports interval override env vars"
else
    fail "install script missing interval override tunables"
fi

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
