#!/usr/bin/env bash
# scripts/ci/test-offline-check-linter.sh — INFRA-1418
#
# Validates the offline-compliance lint at `chump gap reserve` per
# docs/strategy/OFFLINE_COMPLIANCE_RUBRIC.md §2.
#
# Rounds:
#   1. Anti-offline title (webhook-only)            → BLOCK, exit 1
#   2. Same title + --force-anti-offline (no reason) → exit 2
#   3. Same title + --force-anti-offline + --offline-bypass-reason → ok, audit row
#   4. Clean title                                   → ok
#   5. CHUMP_DISABLE_OFFLINE_CHECK=1 + anti-offline title → ok (bypass)

set -euo pipefail

CHUMP_BIN="${CHUMP_BIN:-/Users/jeffadkins/Projects/Chump/target/debug/chump}"
if [ ! -x "$CHUMP_BIN" ]; then
    echo "FAIL: chump binary not found at $CHUMP_BIN" >&2
    exit 1
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/docs/gaps" "$WORK/.chump-locks" "$WORK/.chump"
cd "$WORK"

# ── Round 1: anti-offline title is blocked ────────────────────────────
set +e
OUT=$(FLEET_029_AMBIENT_GLANCE_SKIP=1 "$CHUMP_BIN" gap reserve --domain INFRA --priority P2 --effort s \
    --title "RESILIENT: state.db status flips ONLY on webhook merged=true" 2>&1)
EXIT=$?
set -e
if [ "$EXIT" -ne 1 ]; then
    echo "FAIL: round 1 — expected exit 1 for anti-offline title, got $EXIT"
    echo "$OUT"
    exit 1
fi
echo "$OUT" | grep -q "OFFLINE_CHECK FAIL" || {
    echo "FAIL: round 1 — expected 'OFFLINE_CHECK FAIL' marker"
    echo "$OUT"
    exit 1
}
echo "$OUT" | grep -q "RUBRIC.md §2" || {
    echo "FAIL: round 1 — output should cite the rubric"
    echo "$OUT"
    exit 1
}
# Verify ambient block event was emitted
grep -q '"kind":"gap_offline_check_block"' .chump-locks/ambient.jsonl || {
    echo "FAIL: round 1 — expected gap_offline_check_block event"
    cat .chump-locks/ambient.jsonl 2>/dev/null
    exit 1
}
echo "PASS: round 1 — anti-offline title blocked"

# ── Round 2: --force-anti-offline without --offline-bypass-reason → exit 2
set +e
OUT=$(FLEET_029_AMBIENT_GLANCE_SKIP=1 "$CHUMP_BIN" gap reserve --domain INFRA --priority P2 --effort s \
    --title "RESILIENT: state.db status flips ONLY on webhook merged=true" \
    --force-anti-offline 2>&1)
EXIT=$?
set -e
if [ "$EXIT" -ne 2 ]; then
    echo "FAIL: round 2 — expected exit 2 (missing reason), got $EXIT"
    echo "$OUT"
    exit 1
fi
echo "$OUT" | grep -q "requires --offline-bypass-reason" || {
    echo "FAIL: round 2 — expected reason-required message"
    echo "$OUT"
    exit 1
}
echo "PASS: round 2 — force without reason exits 2"

# ── Round 3: --force-anti-offline + --offline-bypass-reason → ok ───────
set +e
OUT=$(FLEET_029_AMBIENT_GLANCE_SKIP=1 "$CHUMP_BIN" gap reserve --domain INFRA --priority P2 --effort s \
    --title "RESILIENT: state.db status flips ONLY on webhook merged=true" \
    --force-anti-offline \
    --offline-bypass-reason "ci-smoke-test bypass for round 3" 2>&1)
EXIT=$?
set -e
# The reserve might still exit 1 from the similarity check (round 1 created
# a gap with the same title). Both 0 and 1 are acceptable here as long as
# the offline-check passed.
echo "$OUT" | grep -q "OFFLINE_CHECK FAIL" || {
    echo "FAIL: round 3 — offline-check should still print FAIL lines"
    echo "$OUT"
    exit 1
}
echo "$OUT" | grep -q "force-anti-offline accepted" || {
    echo "FAIL: round 3 — expected 'force-anti-offline accepted' message"
    echo "$OUT"
    exit 1
}
# Verify audit row written
AUDIT=$(sqlite3 .chump/state.db \
    "SELECT count(*) FROM gap_offline_bypass_audit WHERE reason LIKE '%round 3%'")
[ "$AUDIT" -eq 1 ] || {
    echo "FAIL: round 3 — expected 1 audit row, got $AUDIT"
    sqlite3 .chump/state.db "SELECT * FROM gap_offline_bypass_audit" 2>&1
    exit 1
}
# Verify ambient bypass event
grep -q '"kind":"gap_offline_bypass"' .chump-locks/ambient.jsonl || {
    echo "FAIL: round 3 — expected gap_offline_bypass event"
    exit 1
}
echo "PASS: round 3 — force + reason accepted, audit row written"

# ── Round 4: clean title passes ────────────────────────────────────────
set +e
OUT=$(FLEET_029_AMBIENT_GLANCE_SKIP=1 "$CHUMP_BIN" gap reserve --domain INFRA --priority P2 --effort s \
    --title "EFFECTIVE: clean title with no anti-offline framing" 2>&1)
EXIT=$?
set -e
echo "$OUT" | grep -q "OFFLINE_CHECK FAIL" && {
    echo "FAIL: round 4 — clean title should NOT trip offline-check"
    echo "$OUT"
    exit 1
}
echo "PASS: round 4 — clean title passes offline-check"

# ── Round 5: CHUMP_DISABLE_OFFLINE_CHECK=1 → bypass entirely ────────────
set +e
OUT=$(CHUMP_DISABLE_OFFLINE_CHECK=1 FLEET_029_AMBIENT_GLANCE_SKIP=1 "$CHUMP_BIN" gap reserve --domain INFRA \
    --priority P2 --effort s \
    --title "RESILIENT: webhook ONLY auto-merge on every PR open event" 2>&1)
EXIT=$?
set -e
echo "$OUT" | grep -q "OFFLINE_CHECK FAIL" && {
    echo "FAIL: round 5 — CHUMP_DISABLE_OFFLINE_CHECK=1 should suppress all output"
    echo "$OUT"
    exit 1
}
echo "PASS: round 5 — disable env bypasses check entirely"

echo ""
echo "All 5 rounds PASSED — INFRA-1418 offline-check linter works"
