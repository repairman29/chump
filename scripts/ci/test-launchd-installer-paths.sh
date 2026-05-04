#!/usr/bin/env bash
# test-launchd-installer-paths.sh — INFRA-451
#
# Verifies that launchd install scripts resolve REPO to the *main* worktree
# even when the install script itself is invoked from a linked worktree.
# Without the fix (resolve_main_worktree), REPO would be the linked-worktree
# path baked into the plist — which dies as soon as that worktree is reaped.

set -euo pipefail

PASS=0
FAIL=0
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

REPO_ROOT="$(git rev-parse --show-toplevel)"
HELPER="$REPO_ROOT/scripts/lib/resolve-main-worktree.sh"

if [[ ! -f "$HELPER" ]]; then
  echo "FATAL: helper not found at $HELPER"; exit 2
fi

echo "=== INFRA-451 launchd installer path-resolution test ==="
echo

# --- Test 1: helper resolves correctly when run from a linked worktree ---
TMPDIR_BASE="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_BASE"' EXIT

# Build a fake repo with a linked worktree
FAKE="$TMPDIR_BASE/main"
mkdir -p "$FAKE/scripts/lib" "$FAKE/scripts/setup"
git -C "$FAKE" init -q -b main
git -C "$FAKE" config user.email t@t.com
git -C "$FAKE" config user.name t
cp "$HELPER" "$FAKE/scripts/lib/"

# Add a stub install script that uses the helper
cat >"$FAKE/scripts/setup/install-fake-launchd.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/../lib/resolve-main-worktree.sh"
REPO="$(resolve_main_worktree "$0")"
echo "$REPO"
SH
chmod +x "$FAKE/scripts/setup/install-fake-launchd.sh"
git -C "$FAKE" add . >/dev/null
git -C "$FAKE" commit -q -m "seed"

# Make a linked worktree off main
LINKED="$TMPDIR_BASE/linked"
git -C "$FAKE" worktree add -q -b linked-test "$LINKED" main

# Run install script from inside the linked worktree
RESOLVED="$(bash "$LINKED/scripts/setup/install-fake-launchd.sh" 2>&1)"
# Canonicalize for macOS where /var is a symlink to /private/var
RESOLVED="$(cd "$RESOLVED" && pwd -P)"
EXPECTED="$(cd "$FAKE" && pwd -P)"

if [[ "$RESOLVED" == "$EXPECTED" ]]; then
  ok "helper resolves to main worktree from linked worktree ($RESOLVED)"
else
  fail "helper should return $EXPECTED, got $RESOLVED"
fi

# --- Test 2: every real install-*-launchd.sh sources the helper ---
echo
echo "--- Test 2: real installers all use the helper ---"
SHOULD_USE=( $(grep -l 'launchd' "$REPO_ROOT/scripts/setup/"install-*-launchd.sh 2>/dev/null) )
MISSING=()
for f in "${SHOULD_USE[@]}"; do
  # Skip the three that don't bake a REPO path (auto-arm-sweeper, roles, soak-checkpoint)
  if grep -qE 'WorkingDirectory|ProgramArguments.*scripts/' "$f" \
     && ! grep -qF 'resolve_main_worktree' "$f"; then
    MISSING+=("$f")
  fi
done

if [[ ${#MISSING[@]} -eq 0 ]]; then
  ok "all path-baking installers source resolve-main-worktree.sh"
else
  for m in "${MISSING[@]}"; do fail "$m does not call resolve_main_worktree"; done
fi

# --- Test 3: regression — old buggy pattern is gone ---
echo
echo "--- Test 3: legacy buggy REPO=cd-dirname pattern is gone ---"
LEGACY=( $(grep -lF 'REPO="$(cd "$(dirname "$0")/../.." && pwd)"' \
            "$REPO_ROOT/scripts/setup/"install-*-launchd.sh 2>/dev/null) ) || true
if [[ ${#LEGACY[@]} -eq 0 ]]; then
  ok "no installer still uses the legacy CWD-relative REPO pattern"
else
  for l in "${LEGACY[@]}"; do fail "$l still uses legacy REPO=cd-dirname"; done
fi

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
