#!/usr/bin/env bash
# capability-guard-exempt: builds chump in-test via cargo; not subject to runner binary cache lag (CREDIBLE-078)
# scripts/ci/test-import-similarity-block.sh — INFRA-1434
#
# Validates the title-similarity guard added to `chump gap import`.
# Mirrors the INFRA-1149 reserve-time check semantics:
#   - Net-new gap with a title near-identical to an existing one → blocked.
#   - Routine round-trip (existing gap re-imported) → not blocked.
#   - CHUMP_GAP_IMPORT_NO_SIMILARITY=1 → check disabled.
#   - Blocked rows do not persist in state.db; ambient.jsonl gets a
#     gap_import_similarity_block event per blocked row.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CHUMP_BIN="${CHUMP_BIN:-$REPO_ROOT/bin/chump}"
if [ ! -x "$CHUMP_BIN" ]; then
    echo "FAIL: chump binary not found at $CHUMP_BIN — build with 'cargo build --bin chump' first" >&2
    exit 1
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/docs/gaps" "$WORK/.chump-locks" "$WORK/.chump"

# ── Round 1: seed the registry with one gap ──────────────────────────
cat > "$WORK/docs/gaps/INFRA-9001.yaml" <<'YAML'
- id: INFRA-9001
  domain: INFRA
  title: "RESILIENT: cross-machine NATS push routing integration test"
  status: open
  priority: P2
  effort: m
YAML

cd "$WORK"
OUT=$("$CHUMP_BIN" gap import 2>&1)
echo "$OUT" | grep -q "1 inserted" || {
    echo "FAIL: round 1 — expected '1 inserted' (seed gap), got:"
    echo "$OUT"
    exit 1
}
echo "PASS: round 1 — seed gap inserted"

# ── Round 2: file a near-duplicate (should be BLOCKED) ───────────────
cat > "$WORK/docs/gaps/INFRA-9002.yaml" <<'YAML'
- id: INFRA-9002
  domain: INFRA
  title: "RESILIENT: cross-machine NATS push routing integration test"
  status: open
  priority: P2
  effort: m
YAML

set +e
OUT=$("$CHUMP_BIN" gap import 2>&1)
EXIT=$?
set -e
if [ "$EXIT" -eq 0 ]; then
    echo "FAIL: round 2 — expected non-zero exit when row blocked, got 0"
    echo "$OUT"
    exit 1
fi
echo "$OUT" | grep -q "blocked by title-similarity" || {
    echo "FAIL: round 2 — expected 'blocked by title-similarity' message, got:"
    echo "$OUT"
    exit 1
}
echo "PASS: round 2 — near-duplicate blocked, non-zero exit"

# Verify INFRA-9002 is NOT in state.db (was deleted post-import).
# `chump gap show <missing>` exits non-zero AND prints "not found" — match
# either signal so the test stays robust if the message wording shifts.
SHOW_OUT=$("$CHUMP_BIN" gap show INFRA-9002 2>&1 || true)
if echo "$SHOW_OUT" | grep -qE "^- id: INFRA-9002"; then
    echo "FAIL: round 2 — INFRA-9002 should not be in state.db after block, but got:"
    echo "$SHOW_OUT"
    exit 1
fi
echo "PASS: round 2 — blocked gap absent from state.db"

# Verify ambient event was written
grep -q '"kind":"gap_import_similarity_block"' "$WORK/.chump-locks/ambient.jsonl" || {
    echo "FAIL: round 2 — expected gap_import_similarity_block event in ambient.jsonl"
    cat "$WORK/.chump-locks/ambient.jsonl" 2>/dev/null || echo "(ambient.jsonl missing)"
    exit 1
}
grep -q '"proposed_id":"INFRA-9002"' "$WORK/.chump-locks/ambient.jsonl" || {
    echo "FAIL: round 2 — ambient event missing proposed_id=INFRA-9002"
    grep "gap_import_similarity_block" "$WORK/.chump-locks/ambient.jsonl"
    exit 1
}
echo "PASS: round 2 — ambient event emitted"

# ── Round 3: round-trip existing gap (should NOT block) ──────────────
# Re-importing INFRA-9001 (already in DB) must not fire similarity check.
set +e
OUT=$("$CHUMP_BIN" gap import 2>&1)
EXIT=$?
set -e
# Round 2 left INFRA-9002.yaml on disk. Remove it so this round only
# sees INFRA-9001 (existing) — clean dump→import scenario.
rm -f "$WORK/docs/gaps/INFRA-9002.yaml"
OUT=$("$CHUMP_BIN" gap import 2>&1)
EXIT=$?
if [ "$EXIT" -ne 0 ]; then
    echo "FAIL: round 3 — round-trip of existing gap should exit 0, got $EXIT"
    echo "$OUT"
    exit 1
fi
echo "$OUT" | grep -q "blocked by title-similarity" && {
    echo "FAIL: round 3 — round-trip should NOT trigger similarity block"
    echo "$OUT"
    exit 1
}
echo "PASS: round 3 — existing gap re-import not blocked"

# ── Round 4: bypass via CHUMP_GAP_IMPORT_NO_SIMILARITY=1 ─────────────
cat > "$WORK/docs/gaps/INFRA-9003.yaml" <<'YAML'
- id: INFRA-9003
  domain: INFRA
  title: "RESILIENT: cross-machine NATS push routing integration test"
  status: open
  priority: P2
  effort: m
YAML

OUT=$(CHUMP_GAP_IMPORT_NO_SIMILARITY=1 "$CHUMP_BIN" gap import 2>&1)
EXIT=$?
if [ "$EXIT" -ne 0 ]; then
    echo "FAIL: round 4 — bypass env should allow import, got exit $EXIT"
    echo "$OUT"
    exit 1
fi
echo "$OUT" | grep -q "1 inserted" || {
    echo "FAIL: round 4 — bypass should report 1 inserted, got:"
    echo "$OUT"
    exit 1
}
SHOW9003=$(CHUMP_BINARY_STALENESS_CHECK=0 "$CHUMP_BIN" gap show INFRA-9003 2>&1 || true)
echo "$SHOW9003" | grep -qE "^- id: INFRA-9003" || {
    echo "FAIL: round 4 — INFRA-9003 should be in state.db when bypass used. show output:"
    echo "$SHOW9003"
    exit 1
}
echo "PASS: round 4 — bypass env var allows duplicate-title import"

echo ""
echo "All 4 rounds PASSED — INFRA-1434 import-time similarity guard works"
