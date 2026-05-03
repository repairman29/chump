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
#   ./scripts/ci/test-duplicate-id-guard.sh
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
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
HOOK="$REPO_ROOT/scripts/git-hooks/pre-commit"

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
# INFRA-200 raw-YAML-edit guard: this synthetic test edits docs/gaps/*.yaml
# directly and has no chump CLI marker. Disable so we exercise ONLY the
# duplicate-ID guard.
export CHUMP_RAW_YAML_LOCK=0
# INFRA-014 recycled-ID guard / hijack guard / closed_pr guard / scope guard
# all key off origin/main. The synthetic repos may or may not have it.
# Disable here so a single fail point is exercised.
export CHUMP_GAPS_LOCK=${CHUMP_GAPS_LOCK:-1}
export CHUMP_SCOPE_CHECK=0
export CHUMP_PREREG_CHECK=0
export CHUMP_PREREG_CONTENT_CHECK=0
export CHUMP_CROSS_JUDGE_CHECK=0
export CHUMP_CREDENTIAL_CHECK=0
export CHUMP_BOOK_SYNC_CHECK=0

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

# ── 3b. Pre-existing duplicate on baseline + UNRELATED edit passes (INFRA-380) ──
echo "--- Test 3b: pre-existing dup on baseline, unrelated edit allowed ---"
#
# Concrete failure mode (INFRA-078, refined by INFRA-380): a duplicate id
# already lives on origin/main (e.g. INFRA-073 collision tracked by INFRA-075).
# Every doc-only PR that touches gaps.yaml had to bypass with CHUMP_GAPS_LOCK=0
# even when introducing no new duplicate. The refinement: only fail when the
# staged commit (a) introduces a NEW dup, or (b) edits a row in an existing
# dup group. Unrelated edits in a repo with a pre-existing dup must pass.

FAKE_REPO_3B="$TMPDIR_BASE/repo3b"
mkdir -p "$FAKE_REPO_3B/docs/gaps" "$FAKE_REPO_3B/.git/hooks"
git -C "$FAKE_REPO_3B" init -q
git -C "$FAKE_REPO_3B" config user.email "test@test.com"
git -C "$FAKE_REPO_3B" config user.name "Test"
cp "$HOOK" "$FAKE_REPO_3B/.git/hooks/pre-commit"
chmod +x "$FAKE_REPO_3B/.git/hooks/pre-commit"

# Two per-file YAMLs that BOTH declare id: TEST-DUP — pre-existing dup on baseline.
cat >"$FAKE_REPO_3B/docs/gaps/TEST-DUP.yaml" <<'YAML'
- id: TEST-DUP
  title: original entry
  status: open
YAML
cat >"$FAKE_REPO_3B/docs/gaps/TEST-DUP-COPY.yaml" <<'YAML'
- id: TEST-DUP
  title: pre-existing dup
  status: open
YAML
cat >"$FAKE_REPO_3B/docs/gaps/TEST-A.yaml" <<'YAML'
- id: TEST-A
  title: unrelated gap
  status: open
YAML
git -C "$FAKE_REPO_3B" add docs/gaps/
# Use --no-verify on the seeding commit since we're intentionally seeding
# a state the OLD guard would have rejected.
git -C "$FAKE_REPO_3B" commit --no-verify -q -m "init with pre-existing dup"
# Make HEAD reachable as origin/main so the guard's baseline lookup works.
git -C "$FAKE_REPO_3B" update-ref refs/remotes/origin/main HEAD

# Make an UNRELATED edit (touching TEST-A only). Should be allowed —
# the dup is pre-existing on baseline and this commit doesn't touch it.
# Keep title/description verbatim so the gap-ID hijack guard doesn't fire.
cat >"$FAKE_REPO_3B/docs/gaps/TEST-A.yaml" <<'YAML'
- id: TEST-A
  title: unrelated gap
  status: open
  notes: harmless tweak
YAML
git -C "$FAKE_REPO_3B" add docs/gaps/TEST-A.yaml

if out=$(git -C "$FAKE_REPO_3B" commit -m "unrelated edit while dup exists" 2>&1); then
    if echo "$out" | grep -q "pre-existing duplicate gap id"; then
        ok "pre-existing dup warning printed; unrelated edit allowed"
    else
        ok "unrelated edit allowed (warning optional)"
    fi
else
    fail "hook blocked an unrelated edit when dup is pre-existing on baseline; output: $out"
fi

# ── 3c. Pre-existing duplicate + EDIT to dup row IS blocked (INFRA-380) ──
echo "--- Test 3c: pre-existing dup, edit TO the dup row, blocks ---"

# Edit one of the dup rows — should still block because the staged diff
# touches an id that's part of a pre-existing dup group.
cat >"$FAKE_REPO_3B/docs/gaps/TEST-DUP-COPY.yaml" <<'YAML'
- id: TEST-DUP
  title: pre-existing dup — touched
  status: open
YAML
git -C "$FAKE_REPO_3B" add docs/gaps/TEST-DUP-COPY.yaml

if out=$(git -C "$FAKE_REPO_3B" commit -m "edit TO dup row" 2>&1); then
    fail "hook allowed an edit TO a pre-existing dup row; output: $out"
else
    if echo "$out" | grep -q "DUPLICATE GAP ID" && echo "$out" | grep -q "TEST-DUP"; then
        ok "edit TO pre-existing dup row blocked with TEST-DUP named"
    else
        fail "hook blocked but with unexpected message; output: $out"
    fi
fi

# Reset state.
git -C "$FAKE_REPO_3B" reset --hard -q HEAD

# ── 4. CI integrity check catches concurrent-branch duplicate (INFRA-075) ──
echo "--- Test 4: scripts/coord/check-gaps-integrity.py catches a concurrent-branch dup ---"
#
# Concrete incident: PR #544 and Cold Water issue #6 commit d448c4e each added
# `- id: INFRA-073` from independent branches. The pre-commit guard runs on
# the locally-staged file only, so each branch passed individually. After the
# merge queue rebased the second PR onto a main that already had INFRA-073,
# the rebased gaps.yaml carried two entries with the same id — but pre-commit
# does not run on server-side rebases. This regression test confirms the CI
# check (scripts/coord/check-gaps-integrity.py) flags the post-rebase dup state
# pre-commit cannot see.

INTEGRITY="$REPO_ROOT/scripts/coord/check-gaps-integrity.py"
if [ ! -f "$INTEGRITY" ]; then
    fail "missing scripts/coord/check-gaps-integrity.py"
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
