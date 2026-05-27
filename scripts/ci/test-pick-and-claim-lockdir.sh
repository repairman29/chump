#!/usr/bin/env bash
# test-pick-and-claim-lockdir.sh — INFRA-467
#
# Verifies _pick_and_claim_gap.py's get_lock_dir() resolves to the *main*
# repo's .chump-locks/ when called from a linked worktree, not the
# worktree's own .chump-locks/. Without this fix (pre-INFRA-467), fleet
# workers spawned from /tmp/chump-fleet-host wrote leases to that
# worktree's local lock dir — invisible to siblings on the main repo
# (INFRA-466 was the surface bug).

set -euo pipefail

PASS=0
FAIL=0
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

REPO_ROOT="$(git rev-parse --show-toplevel)"
PICKER="$REPO_ROOT/scripts/dispatch/_pick_and_claim_gap.py"

[[ -f "$PICKER" ]] || { echo "FATAL: picker missing"; exit 2; }

echo "=== INFRA-467 _pick_and_claim_gap.py lock-dir resolution test ==="
echo

TMPDIR_BASE="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_BASE"' EXIT

# Build a fake main repo and a linked worktree.
FAKE_MAIN="$TMPDIR_BASE/main"
mkdir -p "$FAKE_MAIN/scripts/dispatch"
git -C "$FAKE_MAIN" init -q -b main
git -C "$FAKE_MAIN" config user.email t@t.com
git -C "$FAKE_MAIN" config user.name t
cp "$PICKER" "$FAKE_MAIN/scripts/dispatch/"
git -C "$FAKE_MAIN" add . >/dev/null
git -C "$FAKE_MAIN" commit -q -m seed

LINKED="$TMPDIR_BASE/linked"
git -C "$FAKE_MAIN" worktree add -q -b linked-test "$LINKED" main 2>/dev/null

# INFRA-2073: unset CHUMP_LOCK_DIR + REPO_ROOT to prevent CI runner env from
# bleeding into the synth resolution. Without this, the CI runner's
# /Users/.../actions-runner-chump/.../.chump-locks beats the synth path.
unset CHUMP_LOCK_DIR REPO_ROOT

# --- Test 1: invoking get_lock_dir() from main returns main's .chump-locks ---
RESOLVED_MAIN=$(cd "$FAKE_MAIN" && python3 -c "
import sys
sys.path.insert(0, 'scripts/dispatch')
import _pick_and_claim_gap as m
print(m.get_lock_dir())
")
EXPECTED_MAIN="$(cd "$FAKE_MAIN" && pwd -P)/.chump-locks"
RESOLVED_MAIN_CANON="$(cd "$(dirname "$RESOLVED_MAIN")" 2>/dev/null && pwd -P)/$(basename "$RESOLVED_MAIN")"

if [[ "$RESOLVED_MAIN_CANON" == "$EXPECTED_MAIN" ]]; then
    ok "from main repo: resolves to main/.chump-locks ($RESOLVED_MAIN_CANON)"
else
    fail "from main: expected $EXPECTED_MAIN, got $RESOLVED_MAIN_CANON"
fi

# --- Test 2: invoking from linked worktree ALSO returns main's .chump-locks ---
RESOLVED_LINKED=$(cd "$LINKED" && python3 -c "
import sys
sys.path.insert(0, 'scripts/dispatch')
import _pick_and_claim_gap as m
print(m.get_lock_dir())
")
RESOLVED_LINKED_CANON="$(cd "$(dirname "$RESOLVED_LINKED")" 2>/dev/null && pwd -P)/$(basename "$RESOLVED_LINKED")"

if [[ "$RESOLVED_LINKED_CANON" == "$EXPECTED_MAIN" ]]; then
    ok "from LINKED worktree: also resolves to main/.chump-locks (cross-worktree visibility preserved)"
else
    fail "from linked: expected $EXPECTED_MAIN, got $RESOLVED_LINKED_CANON"
fi

# --- Test 3: CHUMP_LOCK_DIR env override beats git resolution ---
RESOLVED_OVERRIDE=$(CHUMP_LOCK_DIR=/tmp/explicit-test cd "$LINKED" && \
    CHUMP_LOCK_DIR=/tmp/explicit-test python3 -c "
import sys
sys.path.insert(0, 'scripts/dispatch')
import _pick_and_claim_gap as m
print(m.get_lock_dir())
")

if [[ "$RESOLVED_OVERRIDE" == "/tmp/explicit-test" ]]; then
    ok "CHUMP_LOCK_DIR env override is honored"
else
    fail "expected /tmp/explicit-test, got $RESOLVED_OVERRIDE"
fi

# --- Test 4: regression — naive REPO_ROOT/.chump-locks pattern is gone ---
if grep -qE 'return Path\(repo_root\) / "\.chump-locks"$' "$PICKER" \
   && ! grep -q 'INFRA-467' "$PICKER"; then
    fail "naive REPO_ROOT-only resolution still present without INFRA-467 fix marker"
else
    ok "INFRA-467 fix marker present + naive-only path is no longer the default"
fi

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
