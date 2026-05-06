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
#   (5) (INFRA-234) Hook allows additive enrichment of a status:done row
#       — adding closed_pr / closed_date / notes — without flagging it
#       as a reopen.
#   (6) (INFRA-234) Hook does not false-fire when a status:done gap's
#       description block contains the literal text "status: open" —
#       the parser must pin to exact gap-row indentation, not loose
#       `\s*` (which matched description content as a real status
#       field). Same fix shape as INFRA-220 for the closed_pr guard.
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
export CHUMP_RAW_YAML_LOCK=0  # tests legacy docs/gaps.yaml path; raw-YAML guard is a different concern

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
git -C "$FAKE_REPO" checkout -q docs/gaps.yaml 2>/dev/null || true

# ── Test 5 (INFRA-234): additive enrichment of a status:done row is allowed ──
# Reproducer: origin/main has TEST-A status:done, no closed_pr. Local edit
# adds closed_pr + closed_date. Status stays done. Guard MUST allow this.
echo "--- Test 5 (INFRA-234): adding closed_pr/closed_date to status:done is allowed ---"
cat >"$FAKE_REPO/docs/gaps.yaml" <<'YAML'
gaps:
- id: TEST-A
  title: closed gap A
  status: done
  closed_date: '2026-04-20'
  closed_pr: 999
- id: TEST-B
  title: open gap B
  status: open
YAML
git -C "$FAKE_REPO" add docs/gaps.yaml
if git -C "$FAKE_REPO" commit -q -m "add closed_pr to TEST-A" 2>/dev/null; then
    ok "additive closed_pr/closed_date enrichment allowed"
    git -C "$FAKE_REPO" reset -q --hard HEAD~1
else
    fail "hook FALSE-FIRED on additive closed_pr enrichment of done gap"
fi

# ── Test 6 (INFRA-234): status:done with 'status: open' inside description ──
# A done gap whose description contains the literal text 'status: open' (e.g.
# describing a reproducer scenario) must NOT be parsed as having status:open.
# This is the bug seeded into the live registry by INFRA-245's description.
# Setup: seed TEST-D done with the false-positive description, then make any
# unrelated edit that re-stages the file. The parser used to mis-classify
# TEST-D as status='open' from the description body, then complain TEST-D
# was being reopened.
echo "--- Test 6 (INFRA-234): description content does NOT trip the guard ---"
# Add TEST-D as status:done on main with a CLEAN description (no false-positive
# trigger). Include closed_pr to satisfy the INFRA-107 closed_pr-integrity guard.
# We then edit TEST-D to ADD a description body containing 'status: open' text —
# the buggy loose-regex parser then reads NEW[TEST-D]='open,' from the
# description body while OLD[TEST-D]='done' from origin/main, triggering a
# false-positive recycled-ID error.
cat >"$FAKE_REPO/docs/gaps.yaml" <<'YAML'
gaps:
- id: TEST-A
  title: closed gap A
  status: done
  closed_date: '2026-04-20'
- id: TEST-B
  title: open gap B
  status: open
- id: TEST-D
  title: gap that will get a tricky description added
  status: done
  closed_date: '2026-05-01'
  closed_pr: 700
YAML
git -C "$FAKE_REPO" add docs/gaps.yaml
if ! git -C "$FAKE_REPO" commit -q -m "seed TEST-D done (clean)" 2>&1; then
    fail "Test 6 seed commit failed (could not seed TEST-D); skipping"
    git -C "$FAKE_REPO" reset -q HEAD docs/gaps.yaml
    git -C "$FAKE_REPO" checkout -q docs/gaps.yaml
fi
git -C "$FAKE_REPO" update-ref refs/remotes/origin/main HEAD

# why this is OK (INFRA-097 reference below): INFRA-097 appears only as a
# literal string inside a fake gap description body written to
# $FAKE_REPO/docs/gaps.yaml. No real docs/gaps/INFRA-097.yaml file is read.
# This exercises the guard's false-positive suppression for description text
# that contains "docs/gaps/<ID>.yaml says status:…" phrasing (INFRA-234).
#
# Now ADD a description block to TEST-D that contains the literal text
# 'status: open' on a line by itself (mimics INFRA-245's real description
# pattern that seeded the live false-positive). origin/main had TEST-D
# with no description, so the gap-ID hijack guard's old_desc=="" branch
# means the description ADD passes the hijack guard. The recycled-ID
# guard, however, used to read NEW[TEST-D]='open,' (or 'open') from the
# description body — which combined with OLD[TEST-D]='done' tripped the
# false RECYCLE error. Status field stays done; closed_pr stays 700.
cat >"$FAKE_REPO/docs/gaps.yaml" <<'YAML'
gaps:
- id: TEST-A
  title: closed gap A
  status: done
  closed_date: '2026-04-20'
- id: TEST-B
  title: open gap B
  status: open
- id: TEST-D
  title: gap that will get a tricky description added
  status: done
  closed_date: '2026-05-01'
  closed_pr: 700
  description: |
    Adding a postmortem note. The drift summary read
    status: open, docs/gaps/INFRA-097.yaml says status:done.
YAML
# why this is OK: INFRA-097 above is a literal string inside the fake gap
# description written to $FAKE_REPO/docs/gaps.yaml (an isolated mktemp
# git repo). No real docs/gaps/INFRA-097.yaml file is read. This string
# tests that the recycled-ID guard does not false-fire on description body
# text that resembles a status reference (INFRA-234 regression).
git -C "$FAKE_REPO" add docs/gaps.yaml
if out=$(git -C "$FAKE_REPO" commit -m "add description with 'status: open' text to TEST-D" 2>&1); then
    ok "guard does not false-fire on description-body 'status: open' text"
    git -C "$FAKE_REPO" reset -q --hard HEAD~1
else
    if echo "$out" | grep -q "RECYCLE"; then
        fail "guard FALSE-FIRED on description-body 'status: open' (the INFRA-234 bug)"
        echo "      output: $out"
    else
        fail "hook blocked for unrelated reason; output: $out"
    fi
fi

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
if [ "$FAIL" -gt 0 ]; then
    for f in "${FAILS[@]}"; do echo "  - $f"; done
    exit 1
fi
