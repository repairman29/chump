#!/usr/bin/env bash
# test-merge-driver-gap-yaml.sh — INFRA-310
#
# Test the gap-yaml-add-line merge driver for docs/gaps/*.yaml conflicts.
# Simulates two agents closing the same gap and verifies the driver resolves cleanly.

set -euo pipefail

PASS=0
FAIL=0
ok() { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

echo "=== INFRA-310 docs/gaps/*.yaml merge driver test ==="
echo

REPO_ROOT="$(git rev-parse --show-toplevel)"
DRIVER_SCRIPT="$REPO_ROOT/scripts/git/merge-driver-gap-yaml-add-line.sh"
INSTALLER="$REPO_ROOT/scripts/setup/install-merge-drivers.sh"

if [[ ! -x "$DRIVER_SCRIPT" ]]; then
  echo "FATAL: driver script not found at $DRIVER_SCRIPT"
  exit 2
fi

TMPDIR_BASE="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_BASE"' EXIT

# Set up a fresh fake repo
FAKE="$TMPDIR_BASE/repo"
mkdir -p "$FAKE/docs/gaps" "$FAKE/scripts/git" "$FAKE/scripts/setup"
git -C "$FAKE" init -q -b main
git -C "$FAKE" config user.email "test@test.com"
git -C "$FAKE" config user.name "Test"

cp "$DRIVER_SCRIPT" "$FAKE/scripts/git/"
cp "$INSTALLER" "$FAKE/scripts/setup/"

cat >"$FAKE/.gitattributes" <<'GA'
docs/gaps/*.yaml merge=gap-yaml-add-line
GA

# Create initial gap YAML
mkdir -p "$FAKE/docs/gaps"
cat >"$FAKE/docs/gaps/TEST-001.yaml" <<'YAML'
id: TEST-001
title: Test gap
status: open
YAML

git -C "$FAKE" add .gitattributes scripts/ docs/gaps/
git -C "$FAKE" commit -q -m "seed: gap YAML v1"

# Install drivers
( cd "$FAKE" && bash scripts/setup/install-merge-drivers.sh ) >/dev/null 2>&1

echo "--- Test 1: drivers were registered ---"
if git -C "$FAKE" config --get merge.gap-yaml-add-line.driver >/dev/null; then
  ok "gap-yaml-add-line driver registered"
else
  fail "gap-yaml-add-line driver NOT registered"
fi

echo "--- Test 2: concurrent-close scenario (both sides closing same gap) ---"

# Branch A closes the gap with PR #100
git -C "$FAKE" checkout -q -b branch-A
cat >"$FAKE/docs/gaps/TEST-001.yaml" <<'YAML'
id: TEST-001
title: Test gap
status: done
closed_date: '2026-05-03'
closed_pr: '#100'
YAML
git -C "$FAKE" add docs/gaps/TEST-001.yaml
git -C "$FAKE" commit -q -m "branch-A: close TEST-001 with PR #100"

# Branch B (off main) closes the same gap with PR #101
git -C "$FAKE" checkout -q main
git -C "$FAKE" checkout -q -b branch-B
cat >"$FAKE/docs/gaps/TEST-001.yaml" <<'YAML'
id: TEST-001
title: Test gap
status: done
closed_date: '2026-05-03'
closed_pr: '#101'
YAML
git -C "$FAKE" add docs/gaps/TEST-001.yaml
git -C "$FAKE" commit -q -m "branch-B: close TEST-001 with PR #101"
git -C "$FAKE" checkout -q main
git -C "$FAKE" merge -q --ff-only branch-B
git -C "$FAKE" branch -q -D branch-B

# Rebase branch-A onto main
git -C "$FAKE" checkout -q branch-A
set +e
( cd "$FAKE" && git rebase main 2>&1 ) > "$TMPDIR_BASE/rebase.out"
RC=$?
set -e

if [[ $RC -eq 0 ]]; then
  if ! grep -q "<<<<<<< " "$FAKE/docs/gaps/TEST-001.yaml"; then
    ok "concurrent-close scenario: rebase succeeded without conflict markers"
  else
    fail "rebase succeeded but conflict markers remain"
  fi
else
  # Driver should succeed for gap YAML conflicts
  fail "rebase failed when driver should have resolved it; rc=$RC"
  sed 's/^/      /' < "$TMPDIR_BASE/rebase.out" >&2
  git -C "$FAKE" rebase --abort 2>/dev/null || true
fi

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
