#!/usr/bin/env bash
# test-filing-pr-preflight.sh — regression for INFRA-344.
#
# Verifies that gap-preflight.sh does NOT fail when a gap ID exists locally
# (docs/gaps/<ID>.yaml) but has NOT yet been pushed to origin/main.  This is
# the "filing PR" pattern: reserve + implement in the same branch, ship via
# bot-merge. Previously, post-rebase preflight would fail with:
#
#   [gap-preflight] SKIP INFRA-NNN — not found in gap registry (docs/gaps/ or docs/gaps.yaml).
#   [bot-merge] Gap was completed on main while we rebased — nothing left to push.
#
# Root cause: gap-preflight queried origin/main for the YAML, which naturally
# doesn't have it yet. The "not on main" result was mis-classified as "done on
# main" (INFRA-307 PR #914, INFRA-340 PR #943, both 2026-05-02).
#
# Fix (INFRA-344): gap-preflight.sh now falls back to the local working-tree
# copy (docs/gaps/<ID>.yaml) when the gap is not found on origin/main. If
# found locally with a non-done status, it proceeds — it's a filing PR, not
# a missing registration.
#
# What this test covers:
#   (1) gap-preflight exits 0 when the gap YAML exists locally (docs/gaps/)
#       with status:open but does NOT appear on origin/main.
#   (2) gap-preflight still exits 1 for a truly unregistered gap ID (no local
#       YAML, not on main).
#   (3) gap-preflight still exits 1 when the gap is status:done on main.
#   (4) gap-preflight exits 1 for a locally-done gap that is not on main
#       (suspicious state — don't auto-proceed).
#
# Run:
#   ./scripts/ci/test-filing-pr-preflight.sh
#
# Exits non-zero on any check failure.

set -euo pipefail

PASS=0
FAIL=0
FAILS=()

ok()   { echo "  PASS: $*"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $*"; FAIL=$((FAIL+1)); FAILS+=("$*"); }

ROOT="$(git rev-parse --show-toplevel)"
GAPS_DIR="$ROOT/docs/gaps"

echo "=== INFRA-344: gap-preflight filing-PR local-fallback unit tests ==="
echo

# Use IDs that are extremely unlikely to collide with real gaps or origin/main.
# Format: INFRA-ZTEST-<n> is never a real gap ID (INFRA IDs are plain integers).
# However, gap-preflight enforces ID format from the registry, so we use
# a real-looking numeric suffix with a prefix that won't be on main.
# We'll use TEST domain (always absent on main for synthetic tests).
SYNTHETIC_OPEN="TEST-FILING-PR-344-OPEN"
SYNTHETIC_DONE="TEST-FILING-PR-344-DONE"
SYNTHETIC_BOGUS="TEST-FILING-PR-344-BOGUS-ZZZNEVEREXISTS"

# Create/cleanup synthetic YAML files in docs/gaps/.
# These are the "locally present but not on origin/main" files the test
# is designed to exercise.
cleanup() {
    rm -f "$GAPS_DIR/${SYNTHETIC_OPEN}.yaml" \
          "$GAPS_DIR/${SYNTHETIC_DONE}.yaml" 2>/dev/null || true
}
trap cleanup EXIT

# Write a minimal per-file YAML for a synthetic gap (post-INFRA-188 format).
write_gap_yaml() {
    local id="$1" status="$2"
    cat >"$GAPS_DIR/${id}.yaml" <<YAML
- id: $id
  domain: TEST
  title: synthetic gap for INFRA-344 regression
  status: $status
  priority: P1
  effort: xs
  description: |
    Synthetic gap used by test-filing-pr-preflight.sh (INFRA-344).
    This file is written and removed by the test — never commit it.
YAML
}

# ─── Case 1: locally-open gap, NOT on origin/main → should PASS ──────────────
echo "Case 1: locally-open gap not on main (filing PR pattern)"
write_gap_yaml "$SYNTHETIC_OPEN" "open"

set +e
out1="$(bash "$ROOT/scripts/coord/gap-preflight.sh" "$SYNTHETIC_OPEN" 2>&1)"
rc1=$?
set -e

if [[ "$rc1" -eq 0 ]]; then
    ok "Case 1: gap-preflight exits 0 for locally-open gap not on main"
else
    fail "Case 1: expected exit 0 (locally-open gap is a filing PR — OK), got $rc1"
    echo "  Output: $out1"
fi

if echo "$out1" | grep -q "INFRA-344"; then
    ok "Case 1: output mentions INFRA-344 (attribution present)"
else
    fail "Case 1: expected INFRA-344 mention in info line, got: $out1"
fi

# ─── Case 2: truly bogus ID — no local YAML, not on main → should FAIL ───────
echo "Case 2: bogus gap ID not local AND not on main (unregistered)"
# No YAML written for SYNTHETIC_BOGUS.
rm -f "$GAPS_DIR/${SYNTHETIC_BOGUS}.yaml" 2>/dev/null || true

set +e
out2="$(bash "$ROOT/scripts/coord/gap-preflight.sh" "$SYNTHETIC_BOGUS" 2>&1)"
rc2=$?
set -e

if [[ "$rc2" -ne 0 ]]; then
    ok "Case 2: gap-preflight exits non-zero for truly unregistered gap"
else
    fail "Case 2: expected exit non-zero for bogus gap ID, got 0"
    echo "  Output: $out2"
fi

if echo "$out2" | grep -qE "not found in (gap registry|docs/gaps\.yaml)"; then
    ok "Case 2: output contains 'not found in gap registry'"
else
    fail "Case 2: expected 'not found in gap registry' message"
    echo "  Output: $out2"
fi

# ─── Case 3: locally-done gap, NOT on origin/main → should FAIL ──────────────
echo "Case 3: locally-done gap not on main (suspicious — don't auto-proceed)"
write_gap_yaml "$SYNTHETIC_DONE" "done"

set +e
out3="$(bash "$ROOT/scripts/coord/gap-preflight.sh" "$SYNTHETIC_DONE" 2>&1)"
rc3=$?
set -e

if [[ "$rc3" -ne 0 ]]; then
    ok "Case 3: gap-preflight exits non-zero for locally-done gap not on main"
else
    fail "Case 3: expected exit non-zero for locally-done-but-not-on-main gap, got 0"
    echo "  Output: $out3"
fi

# ─── Case 4: verify existing unregistered rejection still works ───────────────
# The CHUMP_ALLOW_UNREGISTERED_GAP=1 bypass must still work.
echo "Case 4: CHUMP_ALLOW_UNREGISTERED_GAP=1 bypass still lets unregistered through"
# SYNTHETIC_BOGUS still has no local YAML.
set +e
out4="$(CHUMP_ALLOW_UNREGISTERED_GAP=1 bash "$ROOT/scripts/coord/gap-preflight.sh" "$SYNTHETIC_BOGUS" 2>&1)"
rc4=$?
set -e

if [[ "$rc4" -eq 0 ]]; then
    ok "Case 4: CHUMP_ALLOW_UNREGISTERED_GAP=1 bypass exits 0"
else
    fail "Case 4: expected exit 0 with bypass env, got $rc4"
    echo "  Output: $out4"
fi

if echo "$out4" | grep -q "CHUMP_ALLOW_UNREGISTERED_GAP=1"; then
    ok "Case 4: output mentions bypass env"
else
    fail "Case 4: expected bypass env mention in output"
    echo "  Output: $out4"
fi

# ─── Summary ──────────────────────────────────────────────────────────────────
echo
echo "=== Results: $PASS passed, $FAIL failed ==="
if [[ $FAIL -gt 0 ]]; then
    echo
    echo "Failures:"
    for f in "${FAILS[@]}"; do echo "  - $f"; done
    exit 1
fi
echo "ok: INFRA-344 filing-PR preflight local-fallback fix is working correctly"
exit 0
