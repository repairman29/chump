#!/usr/bin/env bash
# test-closed-pr-guard.sh — unit tests for the INFRA-107 closed_pr integrity
# pre-commit guard (scripts/git-hooks/pre-commit).
#
# Acceptance criteria verified:
#   (1) Hook rejects a status:done flip with closed_pr:TBD (PRODUCT-009 fixture).
#   (2) Hook rejects a status:done flip with no closed_pr field.
#   (3) Hook allows a status:done flip with closed_pr: 404.
#   (4) CHUMP_GAPS_LOCK=0 bypasses the check.
#
# Run:
#   ./scripts/ci/test-closed-pr-guard.sh
#
# Exits non-zero on any check failure.

set -euo pipefail

PASS=0
FAIL=0
FAILS=()

ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); FAILS+=("$1"); }

echo "=== INFRA-107 closed_pr guard unit tests ==="
echo

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
HOOK="$REPO_ROOT/scripts/git-hooks/pre-commit"

if [ ! -x "$HOOK" ]; then
    echo "FATAL: pre-commit hook not found or not executable: $HOOK"
    exit 2
fi

TMPDIR_BASE="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_BASE"' EXIT

FAKE_REPO="$TMPDIR_BASE/repo"
mkdir -p "$FAKE_REPO/docs" "$FAKE_REPO/.git/hooks"
git -C "$FAKE_REPO" init -q -b main
git -C "$FAKE_REPO" config user.email "test@test.com"
git -C "$FAKE_REPO" config user.name "Test"
cp "$HOOK" "$FAKE_REPO/.git/hooks/pre-commit"
chmod +x "$FAKE_REPO/.git/hooks/pre-commit"

# Silence unrelated guards.
export CHUMP_LEASE_CHECK=0
export CHUMP_STOMP_WARN=0
export CHUMP_CHECK_BUILD=0
export CHUMP_DOCS_DELTA_CHECK=0
export CHUMP_SUBMODULE_CHECK=0
export CHUMP_PREREG_CHECK=0

# Seed origin/main with two open gaps.
cat >"$FAKE_REPO/docs/gaps.yaml" <<'YAML'
gaps:
- id: PRODUCT-009
  title: product gap used for false-closure incident
  status: open
- id: TEST-B
  title: open gap B
  status: open
YAML
git -C "$FAKE_REPO" add docs/gaps.yaml
git -C "$FAKE_REPO" commit -q -m "seed: open gaps"

# Simulate origin/main.
git -C "$FAKE_REPO" update-ref refs/remotes/origin/main HEAD

# ── Test 1: PRODUCT-009 false-closure fixture — closed_pr:TBD is rejected ────
echo "--- Test 1: status:done with closed_pr:TBD is rejected (PRODUCT-009 fixture) ---"
cat >"$FAKE_REPO/docs/gaps.yaml" <<'YAML'
gaps:
- id: PRODUCT-009
  title: product gap used for false-closure incident
  status: done
  closed_date: '2026-04-20'
  closed_pr: TBD
- id: TEST-B
  title: open gap B
  status: open
YAML
git -C "$FAKE_REPO" add docs/gaps.yaml
if out=$(git -C "$FAKE_REPO" commit -m "false-close PRODUCT-009 closed_pr:TBD" 2>&1); then
    fail "hook allowed closed_pr:TBD closure"
    echo "      output: $out"
else
    if echo "$out" | grep -q "INCOMPLETE CLOSURE" && echo "$out" | grep -q "PRODUCT-009"; then
        ok "closed_pr:TBD rejected with expected INCOMPLETE CLOSURE error"
    else
        fail "hook blocked but wrong message; output: $out"
    fi
fi
git -C "$FAKE_REPO" checkout -q docs/gaps.yaml

# ── Test 2: closure with no closed_pr field is rejected ──────────────────────
echo "--- Test 2: status:done with missing closed_pr is rejected ---"
cat >"$FAKE_REPO/docs/gaps.yaml" <<'YAML'
gaps:
- id: PRODUCT-009
  title: product gap used for false-closure incident
  status: done
  closed_date: '2026-04-20'
- id: TEST-B
  title: open gap B
  status: open
YAML
git -C "$FAKE_REPO" add docs/gaps.yaml
if out=$(git -C "$FAKE_REPO" commit -m "close PRODUCT-009 without closed_pr" 2>&1); then
    fail "hook allowed closure with missing closed_pr"
    echo "      output: $out"
else
    if echo "$out" | grep -q "INCOMPLETE CLOSURE" && echo "$out" | grep -q "PRODUCT-009"; then
        ok "missing closed_pr rejected with expected error"
    else
        fail "hook blocked but wrong message; output: $out"
    fi
fi
git -C "$FAKE_REPO" checkout -q docs/gaps.yaml

# ── Test 3: normal closure with closed_pr: 404 passes ────────────────────────
echo "--- Test 3: status:done with closed_pr: 404 is accepted ---"
cat >"$FAKE_REPO/docs/gaps.yaml" <<'YAML'
gaps:
- id: PRODUCT-009
  title: product gap used for false-closure incident
  status: done
  closed_date: '2026-04-20'
  closed_pr: 404
- id: TEST-B
  title: open gap B
  status: open
YAML
git -C "$FAKE_REPO" add docs/gaps.yaml
if git -C "$FAKE_REPO" commit -q -m "properly close PRODUCT-009 closed_pr:404" 2>/dev/null; then
    ok "numeric closed_pr:404 accepted"
    git -C "$FAKE_REPO" reset -q --hard HEAD~1
else
    fail "hook rejected a valid closure with closed_pr: 404"
fi

# ── Test 4: CHUMP_GAPS_LOCK=0 bypasses the guard ─────────────────────────────
echo "--- Test 4: CHUMP_GAPS_LOCK=0 bypasses the closed_pr guard ---"
cat >"$FAKE_REPO/docs/gaps.yaml" <<'YAML'
gaps:
- id: PRODUCT-009
  title: product gap used for false-closure incident
  status: done
  closed_date: '2026-04-20'
  closed_pr: TBD
- id: TEST-B
  title: open gap B
  status: open
YAML
git -C "$FAKE_REPO" add docs/gaps.yaml
if CHUMP_GAPS_LOCK=0 git -C "$FAKE_REPO" commit -q -m "bypass closed_pr guard" 2>/dev/null; then
    ok "CHUMP_GAPS_LOCK=0 bypass honored"
else
    fail "CHUMP_GAPS_LOCK=0 bypass did not work"
fi

# ── Summary ──────────────────────────────────────────────────────────────────
echo
echo "=== Results: $PASS passed, $FAIL failed ==="
if [ "$FAIL" -gt 0 ]; then
    for f in "${FAILS[@]}"; do echo "  - $f"; done
    exit 1
fi
exit 0
