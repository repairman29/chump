#!/usr/bin/env bash
# test-merge-driver-ci-yml-add-row.sh — INFRA-1199
#
# Tests that the ci-yml merge driver refuses to inject an orphan '- name:' step
# without a matching 'run:' or 'uses:' body (regression guard for INFRA-1199).
# shellcheck disable=SC2015  # ok() always exits 0; A && ok || fail is safe here
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DRIVER="$REPO_ROOT/scripts/git/merge-driver-ci-yml-add-row.sh"

PASS=0; FAIL=0
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

echo "=== INFRA-1199 merge-driver orphan-step rejection test ==="
echo

[[ -x "$DRIVER" ]] || { echo "FATAL: driver not found or not executable: $DRIVER"; exit 2; }

TMPBASE="$(mktemp -d)"
trap 'rm -rf "$TMPBASE"' EXIT

# Shared prefix (ancestor content).
ANCESTOR_BODY='jobs:
  ci:
    steps:
      - name: existing step
        run: echo existing'

# ── Test 1: valid theirs appends a complete step — driver merges ──────────────
echo "--- Test 1: valid append (complete step) ---"
T1="$TMPBASE/t1"; mkdir -p "$T1"

printf '%s\n' "$ANCESTOR_BODY" > "$T1/ancestor.yml"
printf '%s\n' "$ANCESTOR_BODY" > "$T1/ours.yml"
printf '%s\n      - name: new step\n        run: echo new\n' "$ANCESTOR_BODY" > "$T1/theirs.yml"

rc=0; "$DRIVER" "$T1/ancestor.yml" "$T1/ours.yml" "$T1/theirs.yml" 2>/dev/null || rc=$?

[[ $rc -eq 0 ]] \
  && ok "driver exits 0 for valid complete step" \
  || fail "driver should exit 0 for valid complete step (got $rc)"

grep -q 'run: echo new' "$T1/ours.yml" \
  && ok "complete step body present in merged output" \
  || fail "complete step body missing in merged output"

# ── Test 2: theirs appends orphan '- name:' without 'run:' — driver refuses ──
echo "--- Test 2: orphan name-only step (INFRA-1199 regression) ---"
T2="$TMPBASE/t2"; mkdir -p "$T2"

printf '%s\n' "$ANCESTOR_BODY" > "$T2/ancestor.yml"
printf '%s\n' "$ANCESTOR_BODY" > "$T2/ours.yml"
printf '%s\n      - name: orphan step\n' "$ANCESTOR_BODY" > "$T2/theirs.yml"

rc=0; "$DRIVER" "$T2/ancestor.yml" "$T2/ours.yml" "$T2/theirs.yml" 2>/dev/null || rc=$?

[[ $rc -ne 0 ]] \
  && ok "driver exits non-zero for orphan '- name:' (no run:)" \
  || fail "driver should reject orphan '- name:' step (got exit $rc)"

grep -qv 'orphan step' "$T2/ours.yml" \
  && ok "orphan step NOT written to merged output" \
  || fail "orphan step was written to merged output"

# ── Test 3: theirs appends step with 'uses:' instead of 'run:' — driver merges
echo "--- Test 3: uses: body (valid alternative to run:) ---"
T3="$TMPBASE/t3"; mkdir -p "$T3"

printf '%s\n' "$ANCESTOR_BODY" > "$T3/ancestor.yml"
printf '%s\n' "$ANCESTOR_BODY" > "$T3/ours.yml"
printf '%s\n      - name: action step\n        uses: actions/checkout@v4\n' "$ANCESTOR_BODY" > "$T3/theirs.yml"

rc=0; "$DRIVER" "$T3/ancestor.yml" "$T3/ours.yml" "$T3/theirs.yml" 2>/dev/null || rc=$?

[[ $rc -eq 0 ]] \
  && ok "driver exits 0 for step with uses: body" \
  || fail "driver should accept step with uses: body (got $rc)"

grep -q 'uses: actions/checkout' "$T3/ours.yml" \
  && ok "uses: step merged into output" \
  || fail "uses: step missing from merged output"

# ── Test 4: theirs appends two steps, first valid, second orphan — driver refuses
echo "--- Test 4: mixed valid + orphan in theirs_tail ---"
T4="$TMPBASE/t4"; mkdir -p "$T4"

printf '%s\n' "$ANCESTOR_BODY" > "$T4/ancestor.yml"
printf '%s\n' "$ANCESTOR_BODY" > "$T4/ours.yml"
{
  printf '%s\n' "$ANCESTOR_BODY"
  printf '      - name: good step\n        run: echo good\n'
  printf '      - name: bad step\n'
} > "$T4/theirs.yml"

rc=0; "$DRIVER" "$T4/ancestor.yml" "$T4/ours.yml" "$T4/theirs.yml" 2>/dev/null || rc=$?

[[ $rc -ne 0 ]] \
  && ok "driver rejects tail containing any orphan step" \
  || fail "driver should reject tail with mixed valid+orphan (got exit $rc)"

# ── Test 5: theirs is identical to ancestor — driver exits 0, ours unchanged ─
echo "--- Test 5: theirs has no new steps (no-op) ---"
T5="$TMPBASE/t5"; mkdir -p "$T5"

printf '%s\n' "$ANCESTOR_BODY" > "$T5/ancestor.yml"
cp "$T5/ancestor.yml" "$T5/ours.yml"
cp "$T5/ancestor.yml" "$T5/theirs.yml"

rc=0; "$DRIVER" "$T5/ancestor.yml" "$T5/ours.yml" "$T5/theirs.yml" 2>/dev/null || rc=$?

[[ $rc -eq 0 ]] \
  && ok "driver exits 0 when theirs is identical to ancestor (no-op)" \
  || fail "driver should exit 0 for no-op (got $rc)"

# ── Source assertions ──────────────────────────────────────────────────────────
echo "--- Source assertions ---"
grep -q 'INFRA-1199' "$DRIVER" \
  && ok "INFRA-1199 referenced in merge driver" \
  || fail "INFRA-1199 NOT referenced in merge driver"

grep -q 'validate_step_bodies' "$DRIVER" \
  && ok "validate_step_bodies function present" \
  || fail "validate_step_bodies NOT found"

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
