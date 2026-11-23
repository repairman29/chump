#!/usr/bin/env bash
# test-prune-worktrees-launchd.sh — INFRA-832
#
# Validates the prune-worktrees launchd integration:
#  - launchd/com.chump.prune-worktrees.plist exists
#  - scripts/setup/install-prune-worktrees-launchd.sh exists and is executable
#  - plist uses StartCalendarInterval at Hour=3, Minute=0
#  - plist label is com.chump.prune-worktrees
#  - plist runs chump fleet prune-worktrees --apply
#  - install script references resolve-main-worktree (INFRA-451)
#  - uninstall path documented in install script

set -euo pipefail

PASS=0
FAIL=0
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PLIST="$REPO_ROOT/launchd/com.chump.prune-worktrees.plist"
INSTALL="$REPO_ROOT/scripts/setup/install-prune-worktrees-launchd.sh"

echo "=== INFRA-832 prune-worktrees launchd test ==="
echo

# 1. Plist file exists
if [[ -f "$PLIST" ]]; then
    ok "launchd/com.chump.prune-worktrees.plist exists"
else
    fail "launchd/com.chump.prune-worktrees.plist missing"
fi

# 2. Install script exists and is executable
if [[ -x "$INSTALL" ]]; then
    ok "install-prune-worktrees-launchd.sh exists and is executable"
else
    fail "install-prune-worktrees-launchd.sh missing or not executable (got: $(ls -l "$INSTALL" 2>/dev/null || echo 'not found'))"
fi

# 3. Label is correct
if grep -q 'com.chump.prune-worktrees' "$PLIST"; then
    ok "plist label is com.chump.prune-worktrees"
else
    fail "plist label missing or wrong"
fi

# 4. StartCalendarInterval key present (not StartInterval)
if grep -q 'StartCalendarInterval' "$PLIST"; then
    ok "plist uses StartCalendarInterval (not StartInterval)"
else
    fail "plist should use StartCalendarInterval for 3am daily schedule"
fi

# 5. Hour = 3 in plist
if python3 - "$PLIST" <<'PY'
import sys, plistlib
with open(sys.argv[1], 'rb') as f:
    pl = plistlib.load(f)
cal = pl.get('StartCalendarInterval', {})
assert cal.get('Hour') == 3, f"Hour={cal.get('Hour')!r}, want 3"
assert cal.get('Minute') == 0, f"Minute={cal.get('Minute')!r}, want 0"
print('ok')
PY
then
    ok "StartCalendarInterval Hour=3, Minute=0 (03:00 daily)"
else
    fail "StartCalendarInterval Hour/Minute not 3/0 — check plist"
fi

# 6. ProgramArguments includes prune-worktrees --apply
if grep -q 'prune-worktrees' "$PLIST" && grep -q -- '--apply' "$PLIST"; then
    ok "plist runs chump fleet prune-worktrees --apply"
else
    fail "plist ProgramArguments missing prune-worktrees or --apply"
fi

# 7. Install script uses resolve-main-worktree (INFRA-451 protection)
if grep -q 'resolve-main-worktree' "$INSTALL" || grep -q 'resolve_main_worktree' "$INSTALL"; then
    ok "install script uses resolve-main-worktree (INFRA-451)"
else
    fail "install script must use resolve-main-worktree to survive worktree reaping"
fi

# 8. Uninstall documented in install script
if grep -q 'launchctl unload' "$INSTALL" || grep -q 'UNINSTALL\|uninstall' "$INSTALL"; then
    ok "uninstall path documented in install script"
else
    fail "install script should document uninstall procedure"
fi

# 9. Plist RunAtLoad = false (don't prune on install)
if python3 - "$PLIST" <<'PY'
import sys, plistlib
with open(sys.argv[1], 'rb') as f:
    pl = plistlib.load(f)
assert pl.get('RunAtLoad') == False, f"RunAtLoad={pl.get('RunAtLoad')!r}, want False"
print('ok')
PY
then
    ok "RunAtLoad=false (prune not triggered on install)"
else
    fail "RunAtLoad should be false — prune on install could be disruptive"
fi

# 10. Install script is idempotent (launchctl unload before load)
if grep -q 'launchctl unload.*2>/dev/null.*|| true' "$INSTALL"; then
    ok "install script idempotent (unload-before-load with error suppression)"
else
    fail "install script should unload existing agent before re-loading"
fi

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
