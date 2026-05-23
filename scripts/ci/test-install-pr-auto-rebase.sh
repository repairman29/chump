#!/usr/bin/env bash
# scripts/ci/test-install-pr-auto-rebase.sh — INFRA-1779
#
# Structural smoke for scripts/setup/install-pr-auto-rebase-launchd.sh.
# Does NOT actually load the launchd plist (CI runners are not Mac).

set -uo pipefail

PASS=0
FAIL=0
FAILS=()
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); FAILS+=("$1"); }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TARGET="$REPO_ROOT/scripts/setup/install-pr-auto-rebase-launchd.sh"

echo "=== INFRA-1779 pr-auto-rebase plist installer tests ==="

[[ -f "$TARGET" ]] && ok "installer exists" || { fail "missing $TARGET"; exit 1; }
[[ -x "$TARGET" ]] && ok "installer executable" || fail "installer not executable"

# bash syntax check.
if bash -n "$TARGET"; then
    ok "installer passes bash -n"
else
    fail "installer has bash syntax error"
fi

# Structural contract: the installer must mention all the required plist keys
# and the target daemon script.
for needle in \
    "Label" \
    "dev.chump.pr-auto-rebase" \
    "scripts/coord/pr-auto-rebase.sh" \
    "StartInterval" \
    "RunAtLoad" \
    "INTERVAL_MIN.*5" \
    "launchctl load" \
    "launchctl unload" \
    "/tmp/chump-pr-auto-rebase"; do
    if grep -qE "$needle" "$TARGET"; then
        ok "contract: $needle"
    else
        fail "contract missing: $needle"
    fi
done

# Verify it depends on INFRA-1777's script — guard "script not found" path.
if grep -q "INFRA-1777 must land first" "$TARGET"; then
    ok "installer fails-fast if INFRA-1777 daemon absent"
else
    fail "installer missing INFRA-1777 dependency check"
fi

# Verify the sub-5-min clamp is present.
if grep -q "is below 5; clamping to 5" "$TARGET"; then
    ok "installer clamps sub-5-min interval"
else
    fail "installer missing sub-5-min interval clamp"
fi

echo ""
echo "=== Summary: $PASS passed, $FAIL failed ==="
if (( FAIL > 0 )); then
    for f in "${FAILS[@]}"; do printf '  - %s\n' "$f"; done
    exit 1
fi
echo "PASS"
