#!/usr/bin/env bash
# test-recycled-id-guard.sh — unit tests for the INFRA-014 recycled-ID
# pre-commit guard.
#
# Acceptance criteria verified:
#   (1) Hook rejects a commit that flips a gap from status: done (on
#       origin/main) back to status: open under the same id.
#   (2) Hook allows legitimate done->done diffs (e.g. adding resolution_notes).
#   (3) Hook allows a new open gap with a genuinely new id.
#   (4) CHUMP_GAPS_LOCK=0 bypasses the check.
#
# Run:
#   ./scripts/ci/test-recycled-id-guard.sh
#
# Exits non-zero on any check failure.

set -euo pipefail

PASS=0
FAIL=0
FAILS=()

ok() { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); FAILS+=("$1"); }

echo "=== INFRA-014 recycled-ID guard unit tests ==="
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

# Seed an origin/main history that has TEST-A closed as done.
cat >"$FAKE_REPO/docs/gaps.yaml" <<'YAML'
gaps:
- id: TEST-A
  title: closed gap A
  status: done
  closed_date: '2026-04-20'
- id: TEST-B
  title: open gap B
  status: open
YAML
git -C "$FAKE_REPO" add docs/gaps.yaml
git -C "$FAKE_REPO" commit -q -m "seed: TEST-A closed"

# Simulate origin/main by adding a remote alias pointing at this repo's HEAD.
git -C "$FAKE_REPO" update-ref refs/remotes/origin/main HEAD

# ── Test 1: flipping TEST-A done -> open is rejected ─────────────────────────
echo "--- Test 1: reopening a done gap under the same id is blocked ---"
cat >"$FAKE_REPO/docs/gaps.yaml" <<'YAML'
gaps:
- id: TEST-A
  title: closed gap A
  status: open
- id: TEST-B
  title: open gap B
  status: open
YAML
git -C "$FAKE_REPO" add docs/gaps.yaml
if out=$(git -C "$FAKE_REPO" commit -m "reopen TEST-A" 2>&1); then
    fail "hook allowed reopening TEST-A (done -> open)"
    echo "      output: $out"
else
    if echo "$out" | grep -q "RECYCLE" && echo "$out" | grep -q "TEST-A"; then
        ok "recycled-ID guard blocked reopen with expected error"
    else
        fail "hook blocked but wrong message; output: $out"
    fi
fi
git -C "$FAKE_REPO" checkout -q docs/gaps.yaml

# ── Test 2: benign done diff is allowed ──────────────────────────────────────
echo "--- Test 2: done gap stays done (benign edit) is allowed ---"
cat >"$FAKE_REPO/docs/gaps.yaml" <<'YAML'
gaps:
- id: TEST-A
  title: closed gap A
  status: done
  closed_date: '2026-04-20'
  resolution_notes: minor cleanup
- id: TEST-B
  title: open gap B
  status: open
YAML
git -C "$FAKE_REPO" add docs/gaps.yaml
if git -C "$FAKE_REPO" commit -q -m "add resolution_notes to TEST-A" 2>/dev/null; then
    ok "benign done-gap edit allowed"
    git -C "$FAKE_REPO" reset -q --hard HEAD~1
else
    fail "hook blocked benign done-gap edit"
fi

# ── Test 3: fresh new open gap is allowed ────────────────────────────────────
echo "--- Test 3: adding a genuinely new gap is allowed ---"
cat >"$FAKE_REPO/docs/gaps.yaml" <<'YAML'
gaps:
- id: TEST-A
  title: closed gap A
  status: done
  closed_date: '2026-04-20'
- id: TEST-B
  title: open gap B
  status: open
- id: TEST-C
  title: brand-new gap
  status: open
YAML
git -C "$FAKE_REPO" add docs/gaps.yaml
if git -C "$FAKE_REPO" commit -q -m "add TEST-C" 2>/dev/null; then
    ok "new gap with fresh id accepted"
    git -C "$FAKE_REPO" reset -q --hard HEAD~1
else
    fail "hook blocked a legitimate new gap"
fi

# ── Test 4: CHUMP_GAPS_LOCK=0 bypasses the guard ─────────────────────────────
echo "--- Test 4: CHUMP_GAPS_LOCK=0 bypasses ---"
cat >"$FAKE_REPO/docs/gaps.yaml" <<'YAML'
gaps:
- id: TEST-A
  title: closed gap A
  status: open
- id: TEST-B
  title: open gap B
  status: open
YAML
git -C "$FAKE_REPO" add docs/gaps.yaml
if CHUMP_GAPS_LOCK=0 git -C "$FAKE_REPO" commit -q -m "force-reopen with bypass" 2>/dev/null; then
    ok "CHUMP_GAPS_LOCK=0 bypass honored"
else
    fail "bypass env var did not work"
fi

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
if [ "$FAIL" -gt 0 ]; then
    for f in "${FAILS[@]}"; do echo "  - $f"; done
    exit 1
fi
