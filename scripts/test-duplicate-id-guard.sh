#!/usr/bin/env bash
# test-duplicate-id-guard.sh — unit tests for the INFRA-015 duplicate-ID
# pre-commit guard (scripts/git-hooks/pre-commit lines 268-308).
#
# Acceptance criteria verified:
#   (1) Hook rejects a commit that inserts a gaps.yaml entry whose id:
#       already exists elsewhere in the file.
#   (2) Hook allows a commit that adds a gap with a genuinely new id:.
#   (3) CHUMP_GAPS_LOCK=0 bypasses the check.
#   (4) Error message lists the colliding id(s).
#
# Run:
#   ./scripts/test-duplicate-id-guard.sh
#
# Exits non-zero on any check failure.

set -euo pipefail

PASS=0
FAIL=0
FAILS=()

ok() { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); FAILS+=("$1"); }

echo "=== INFRA-015 duplicate-ID guard unit tests ==="
echo

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HOOK="$SCRIPT_DIR/git-hooks/pre-commit"

if [ ! -x "$HOOK" ]; then
    echo "FATAL: pre-commit hook not found or not executable: $HOOK"
    exit 2
fi

TMPDIR_BASE="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_BASE"' EXIT

# Build a minimal fake repo with the hook wired in.
FAKE_REPO="$TMPDIR_BASE/repo"
mkdir -p "$FAKE_REPO/docs" "$FAKE_REPO/.git/hooks"
git -C "$FAKE_REPO" init -q
git -C "$FAKE_REPO" config user.email "test@test.com"
git -C "$FAKE_REPO" config user.name "Test"
cp "$HOOK" "$FAKE_REPO/.git/hooks/pre-commit"
chmod +x "$FAKE_REPO/.git/hooks/pre-commit"

# Disable the unrelated guards that would fire in the synthetic repo
# (lease-check wants .chump-locks/; cargo-check wants a cargo project;
# docs-delta check wants docs/*.md not docs/gaps.yaml).
export CHUMP_LEASE_CHECK=0
export CHUMP_STOMP_WARN=0
export CHUMP_CHECK_BUILD=0
export CHUMP_DOCS_DELTA_CHECK=0
export CHUMP_SUBMODULE_CHECK=0

# Seed initial gaps.yaml with two legitimate entries.
cat >"$FAKE_REPO/docs/gaps.yaml" <<'YAML'
gaps:
- id: TEST-A
  title: first test gap
  status: open
- id: TEST-B
  title: second test gap
  status: open
YAML
git -C "$FAKE_REPO" add docs/gaps.yaml
git -C "$FAKE_REPO" commit -q -m "init gaps.yaml"

# ── 1. Duplicate-ID insert is rejected ───────────────────────────────────────
echo "--- Test 1: insert of duplicate id: blocks the commit ---"

cat >"$FAKE_REPO/docs/gaps.yaml" <<'YAML'
gaps:
- id: TEST-A
  title: first test gap
  status: open
- id: TEST-B
  title: second test gap
  status: open
- id: TEST-A
  title: malicious recycle of TEST-A
  status: open
YAML
git -C "$FAKE_REPO" add docs/gaps.yaml

if out=$(git -C "$FAKE_REPO" commit -m "insert duplicate TEST-A" 2>&1); then
    fail "hook allowed a commit with duplicate TEST-A"
    echo "      output: $out"
else
    if echo "$out" | grep -q "DUPLICATE GAP ID"; then
        if echo "$out" | grep -q "TEST-A"; then
            ok "duplicate TEST-A insert rejected with expected error"
        else
            fail "error did not name the colliding id (TEST-A); output: $out"
        fi
    else
        fail "hook blocked commit but with wrong message; output: $out"
    fi
fi

# Clean up staged state for next test.
git -C "$FAKE_REPO" reset --hard -q HEAD

# ── 2. Non-duplicate insert passes ───────────────────────────────────────────
echo "--- Test 2: insert of a genuinely new id: passes ---"

cat >"$FAKE_REPO/docs/gaps.yaml" <<'YAML'
gaps:
- id: TEST-A
  title: first test gap
  status: open
- id: TEST-B
  title: second test gap
  status: open
- id: TEST-C
  title: brand new unique id
  status: open
YAML
git -C "$FAKE_REPO" add docs/gaps.yaml

if git -C "$FAKE_REPO" commit -q -m "insert unique TEST-C" >"$TMPDIR_BASE/t2.log" 2>&1; then
    ok "non-duplicate TEST-C insert accepted"
else
    fail "hook rejected a legitimate non-duplicate insert; log: $(cat $TMPDIR_BASE/t2.log)"
fi

# ── 3. CHUMP_GAPS_LOCK=0 bypasses the check ──────────────────────────────────
echo "--- Test 3: CHUMP_GAPS_LOCK=0 bypasses the guard ---"

cat >>"$FAKE_REPO/docs/gaps.yaml" <<'YAML'
- id: TEST-C
  title: intentional duplicate bypassed via env
  status: open
YAML
git -C "$FAKE_REPO" add docs/gaps.yaml

if CHUMP_GAPS_LOCK=0 git -C "$FAKE_REPO" commit -q -m "bypass dedup check" >"$TMPDIR_BASE/t3.log" 2>&1; then
    ok "CHUMP_GAPS_LOCK=0 bypass works"
else
    fail "bypass env var did not bypass; log: $(cat $TMPDIR_BASE/t3.log)"
fi

# ── 4. CI integrity check catches concurrent-branch duplicate (INFRA-075) ──
echo "--- Test 4: scripts/check-gaps-integrity.py catches a concurrent-branch dup ---"
#
# Concrete incident: PR #544 and Cold Water issue #6 commit d448c4e each added
# `- id: INFRA-073` from independent branches. The pre-commit guard runs on
# the locally-staged file only, so each branch passed individually. After the
# merge queue rebased the second PR onto a main that already had INFRA-073,
# the rebased gaps.yaml carried two entries with the same id — but pre-commit
# does not run on server-side rebases. This regression test confirms the CI
# check (scripts/check-gaps-integrity.py) flags the post-rebase dup state
# pre-commit cannot see.

INTEGRITY="$SCRIPT_DIR/check-gaps-integrity.py"
if [ ! -f "$INTEGRITY" ]; then
    fail "missing scripts/check-gaps-integrity.py"
elif ! command -v python3 >/dev/null 2>&1; then
    echo "  SKIP: python3 not available"
elif ! python3 -c "import yaml" 2>/dev/null; then
    echo "  SKIP: PyYAML not installed in test env"
else
    DUP_YAML="$TMPDIR_BASE/dup-gaps.yaml"
    cat >"$DUP_YAML" <<'YAML'
gaps:
- id: TEST-A
  title: original
  status: open
- id: TEST-B
  title: branch B added this id concurrently
  status: open
- id: TEST-A
  title: branch C also added this id — surfaces only after rebase onto main
  status: open
YAML

    if out=$(python3 "$INTEGRITY" "$DUP_YAML" 2>&1); then
        fail "integrity check accepted a file with a duplicate id"
        echo "      output: $out"
    else
        if echo "$out" | grep -q "duplicate id"; then
            ok "concurrent-branch duplicate flagged by CI integrity check"
        else
            fail "integrity check rejected file but message missing 'duplicate id'; output: $out"
        fi
    fi

    CLEAN_YAML="$TMPDIR_BASE/clean-gaps.yaml"
    cat >"$CLEAN_YAML" <<'YAML'
gaps:
- id: TEST-A
  title: original
  status: open
- id: TEST-B
  title: distinct id
  status: open
YAML
    if python3 "$INTEGRITY" "$CLEAN_YAML" >/dev/null 2>&1; then
        ok "integrity check accepts a duplicate-free file"
    else
        fail "integrity check rejected a clean file"
    fi
fi

# ── Summary ──────────────────────────────────────────────────────────────────
echo
echo "=== results: $PASS passed, $FAIL failed ==="
if [ "$FAIL" -gt 0 ]; then
    for f in "${FAILS[@]}"; do echo "  - $f"; done
    exit 1
fi
exit 0
