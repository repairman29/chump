#!/usr/bin/env bash
# test-gap-pattern-hold-check.sh — RESILIENT-365 unit tests.
#
# Verifies scripts/coord/gap-pattern-hold-check.sh:
#   (1) No hold file → always exit 0 (proceed)
#   (2) Title matching a held keyword → exit 2 (blocked), prints advisory
#   (3) Title NOT matching any held keyword → exit 0 (proceed)
#   (4) Title referencing the RCA gap id → exit 0 (proceed, already linked)
#   (5) --json mode reports blocked:true/false correctly
#   (6) gap-reserve.sh refuses to reserve a symptom gap under an active hold
#
# Run: ./scripts/ci/test-gap-pattern-hold-check.sh

set -euo pipefail

PASS=0
FAIL=0
FAILS=()

ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); FAILS+=("$1"); }

echo "=== RESILIENT-365 gap-pattern-hold-check unit tests ==="
echo

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
CHECK="$REPO_ROOT/scripts/coord/gap-pattern-hold-check.sh"
RESERVE="$REPO_ROOT/scripts/coord/gap-reserve.sh"

[ -x "$CHECK" ] || chmod +x "$CHECK" 2>/dev/null || true
[ -x "$CHECK" ] || { echo "FATAL: $CHECK not executable"; exit 2; }

TMPDIR_BASE="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_BASE"' EXIT

HOLD_FILE="$TMPDIR_BASE/hold.json"

# ── Test 1: no hold file → exit 0 ─────────────────────────────────────────────
echo "--- Test 1: no hold file present → proceed ---"
rm -f "$HOLD_FILE"
if CHUMP_PATTERN_DETECTOR_HOLD="$HOLD_FILE" "$CHECK" "reconcile drift again" >/dev/null 2>&1; then
    ok "Test 1: exit 0 when no hold file"
else
    fail "Test 1: expected exit 0 when no hold file"
fi

cat > "$HOLD_FILE" <<'JSON'
{
  "holds": {
    "reconcile": {
      "rca_gap": "META-9001",
      "since": "2026-08-21T00:00:00Z",
      "gap_count": 3,
      "gap_ids": "TEST-001,TEST-002,TEST-003",
      "advisory": "New gaps titled with \"reconcile\" should reference META-9001 (depends_on) instead of filing another symptom."
    }
  }
}
JSON

# ── Test 2: matching keyword, no RCA reference → blocked (exit 2) ────────────
echo "--- Test 2: title matches held keyword 'reconcile' → blocked ---"
out=$(CHUMP_PATTERN_DETECTOR_HOLD="$HOLD_FILE" "$CHECK" "reconcile another drift symptom" 2>&1) && rc=0 || rc=$?
if [ "${rc:-0}" -eq 2 ] && echo "$out" | grep -q "META-9001"; then
    ok "Test 2: blocked with exit 2 and RCA gap id in output"
else
    fail "Test 2: expected exit 2 + META-9001 in output; rc=$rc out=$out"
fi

# ── Test 3: title doesn't match any held keyword → proceed ───────────────────
echo "--- Test 3: unrelated title → proceed ---"
if CHUMP_PATTERN_DETECTOR_HOLD="$HOLD_FILE" "$CHECK" "totally unrelated widget polish" >/dev/null 2>&1; then
    ok "Test 3: exit 0 for unrelated title"
else
    fail "Test 3: expected exit 0 for unrelated title"
fi

# ── Test 4: title references the RCA gap id → proceed (already linked) ──────
echo "--- Test 4: title referencing RCA gap id is allowed ---"
if CHUMP_PATTERN_DETECTOR_HOLD="$HOLD_FILE" "$CHECK" "reconcile follow-up per META-9001" >/dev/null 2>&1; then
    ok "Test 4: exit 0 when title already references the RCA gap"
else
    fail "Test 4: expected exit 0 when title references RCA gap id"
fi

# ── Test 5: --json mode ───────────────────────────────────────────────────────
echo "--- Test 5: --json reports blocked:true/false ---"
jout=$(CHUMP_PATTERN_DETECTOR_HOLD="$HOLD_FILE" "$CHECK" --json "reconcile once more" 2>&1)
if echo "$jout" | grep -q '"blocked": *true' && echo "$jout" | grep -q "META-9001"; then
    ok "Test 5a: --json blocked:true for matching title"
else
    fail "Test 5a: expected blocked:true in json; got: $jout"
fi
jout2=$(CHUMP_PATTERN_DETECTOR_HOLD="$HOLD_FILE" "$CHECK" --json "unrelated title" 2>&1)
if echo "$jout2" | grep -q '"blocked": *false'; then
    ok "Test 5b: --json blocked:false for unrelated title"
else
    fail "Test 5b: expected blocked:false in json; got: $jout2"
fi

# ── Test 6: gap-reserve.sh refuses under an active hold ──────────────────────
echo "--- Test 6: gap-reserve.sh blocks reserving a symptom gap under hold ---"
FAKE_REPO="$TMPDIR_BASE/repo"
mkdir -p "$FAKE_REPO/.chump-locks" "$FAKE_REPO/docs/gaps"
git -C "$FAKE_REPO" init -q -b main
git -C "$FAKE_REPO" config user.email t@t
git -C "$FAKE_REPO" config user.name T
git -C "$FAKE_REPO" -c user.email=t@t -c user.name=T commit --allow-empty -q -m init
cp "$HOLD_FILE" "$FAKE_REPO/.chump-locks/pattern-detector-hold.json"

out6=$(cd "$FAKE_REPO" && CHUMP_ALLOW_MAIN_WORKTREE=1 \
    CHUMP_PATTERN_DETECTOR_HOLD="$FAKE_REPO/.chump-locks/pattern-detector-hold.json" \
    "$RESERVE" INFRA "reconcile yet another symptom" 2>&1) && rc6=0 || rc6=$?
if [ "${rc6:-0}" -ne 0 ] && echo "$out6" | grep -q "META-9001"; then
    ok "Test 6: gap-reserve.sh refused symptom gap under active hold"
else
    fail "Test 6: expected gap-reserve.sh to refuse; rc=$rc6 out=$out6"
fi

# ── Summary ──────────────────────────────────────────────────────────────────
echo
echo "=== Results: $PASS passed, $FAIL failed ==="
if [ "$FAIL" -gt 0 ]; then
    for f in "${FAILS[@]}"; do echo "  - $f"; done
    exit 1
fi
exit 0
