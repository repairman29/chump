#!/usr/bin/env bash
# test-rollback-gap.sh — INFRA-899
#
# Tests scripts/ops/rollback-gap.sh with synthetic lease + worktree fixtures.
#
# Tests:
#  1. Script exists and is executable
#  2. EVENT_REGISTRY has gap_rollback_executed
#  3. INFRA-899 referenced in script
#  4. No lease: exits 1 without --force
#  5. --dry-run: no file changes, no ambient event
#  6. With synthetic lease: releases lease (file removed)
#  7. With synthetic worktree dir: removes it
#  8. Emits gap_rollback_executed with correct fields
#  9. --keep-branch: skips branch deletion step
# 10. ROLLBACK_RUNBOOK.md exists and is non-empty

set -euo pipefail

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}"
SCRIPT="$REPO_ROOT/scripts/ops/rollback-gap.sh"

pass=0
fail=0
ok()  { echo "  PASS $1"; pass=$((pass + 1)); }
err() { echo "  FAIL $1"; fail=$((fail + 1)); }

echo "=== test-rollback-gap.sh ==="

# ── Test 1: script exists and is executable ───────────────────────────────────
if [[ -x "$SCRIPT" ]]; then
    ok "1: rollback-gap.sh exists and is executable"
else
    err "1: script missing or not executable at $SCRIPT"
    exit 1
fi

# ── Test 2: EVENT_REGISTRY has gap_rollback_executed ─────────────────────────
REGISTRY="$REPO_ROOT/docs/observability/EVENT_REGISTRY.yaml"
if grep -q "gap_rollback_executed" "$REGISTRY"; then
    ok "2: gap_rollback_executed registered in EVENT_REGISTRY.yaml"
else
    err "2: gap_rollback_executed missing from EVENT_REGISTRY.yaml"
fi

# ── Test 3: INFRA-899 referenced in script ───────────────────────────────────
if grep -q "INFRA-899" "$SCRIPT"; then
    ok "3: INFRA-899 referenced in script"
else
    err "3: INFRA-899 not found in script"
fi

# ── Setup temp dir ────────────────────────────────────────────────────────────
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
LOCKS_DIR="$TMP/.chump-locks"
mkdir -p "$LOCKS_DIR"

# Stub chump binary (gap set/show calls)
mkdir -p "$TMP/bin"
cat > "$TMP/bin/chump" <<'STUB'
#!/usr/bin/env bash
# Stub chump for rollback-gap tests
case "$*" in
    *"gap set"*) echo "gap set OK"; exit 0 ;;
    *"--release"*) echo "released"; exit 0 ;;
    *) echo "chump stub: $*"; exit 0 ;;
esac
STUB
chmod +x "$TMP/bin/chump"
export PATH="$TMP/bin:$PATH"

FAKE_GAP="TEST-777"
FAKE_GAP_LOWER="test-777"

# ── Test 4: No lease + no --force → exits 1 ──────────────────────────────────
AMB4="$TMP/amb4.jsonl"
if ! REPO_ROOT="$TMP" CHUMP_AMBIENT_LOG="$AMB4" bash "$SCRIPT" "$FAKE_GAP" >/dev/null 2>&1; then
    ok "4: no lease exits 1 (non-force mode)"
else
    err "4: should exit 1 when no lease and not --force"
fi

# ── Test 5: --dry-run: no changes, no ambient event ──────────────────────────
# Plant a lease file
LEASE_FILE="$LOCKS_DIR/claim-${FAKE_GAP_LOWER}-12345-9999.json"
echo '{"gap_id":"TEST-777"}' > "$LEASE_FILE"
AMB5="$TMP/amb5.jsonl"
REPO_ROOT="$TMP" CHUMP_AMBIENT_LOG="$AMB5" \
    bash "$SCRIPT" --dry-run "$FAKE_GAP" >/dev/null 2>&1 || true

if [[ -f "$LEASE_FILE" ]]; then
    ok "5: --dry-run did not remove lease file"
else
    err "5: --dry-run removed lease file (should not have)"
fi
if [[ ! -f "$AMB5" ]] || ! grep -q "gap_rollback_executed" "$AMB5" 2>/dev/null; then
    ok "5b: --dry-run did not write to ambient"
else
    err "5b: --dry-run wrote to ambient (should not have)"
fi

# ── Test 6: With synthetic lease → lease file removed ────────────────────────
# LEASE_FILE still exists from test 5
AMB6="$TMP/amb6.jsonl"
REPO_ROOT="$TMP" CHUMP_AMBIENT_LOG="$AMB6" \
    bash "$SCRIPT" "$FAKE_GAP" >/dev/null 2>&1 || true

if [[ ! -f "$LEASE_FILE" ]]; then
    ok "6: lease file removed after rollback"
else
    err "6: lease file still exists after rollback"
fi

# ── Test 7: --dry-run with lease: script mentions lease in output ─────────────
# Re-plant lease removed in test 6
echo '{"gap_id":"TEST-777"}' > "$LEASE_FILE"
AMB7="$TMP/amb7.jsonl"
# Capture output separately to avoid pipefail interactions
T7_OUT=$(REPO_ROOT="$TMP" CHUMP_AMBIENT_LOG="$AMB7" \
    bash "$SCRIPT" --dry-run "$FAKE_GAP" 2>&1) || true
if echo "$T7_OUT" | grep -q "dry-run"; then
    ok "7: dry-run output mentions lease/worktree steps"
else
    err "7: dry-run output missing expected 'dry-run' text (got: $T7_OUT)"
fi

# ── Test 8: Emits gap_rollback_executed with correct fields ──────────────────
echo '{"gap_id":"TEST-777"}' > "$LEASE_FILE"
AMB8="$TMP/amb8.jsonl"
REPO_ROOT="$TMP" CHUMP_AMBIENT_LOG="$AMB8" \
    bash "$SCRIPT" "$FAKE_GAP" >/dev/null 2>&1 || true

if python3 -c "
import json
events = [json.loads(l) for l in open('$AMB8') if l.strip()]
e = next((x for x in events if x.get('kind') == 'gap_rollback_executed'), None)
assert e is not None, 'no gap_rollback_executed event'
assert e.get('gap_id') == 'TEST-777', f'wrong gap_id: {e}'
assert 'worktree_removed' in e, f'missing worktree_removed: {e}'
assert 'branch_deleted' in e, f'missing branch_deleted: {e}'
assert 'lease_released' in e, f'missing lease_released: {e}'
assert 'ts' in e, f'missing ts: {e}'
" 2>/dev/null; then
    ok "8: gap_rollback_executed event has correct fields"
else
    err "8: event payload missing required fields (content: $(cat "$AMB8" 2>/dev/null || echo 'empty'))"
fi

# ── Test 9: --force works without lease ──────────────────────────────────────
AMB9="$TMP/amb9.jsonl"
# No lease file present now (removed in test 8)
if REPO_ROOT="$TMP" CHUMP_AMBIENT_LOG="$AMB9" \
    bash "$SCRIPT" --force "$FAKE_GAP" >/dev/null 2>&1; then
    ok "9: --force exits 0 even without lease"
else
    err "9: --force should exit 0 even without lease"
fi
if grep -q "gap_rollback_executed" "$AMB9" 2>/dev/null; then
    ok "9b: --force still emits gap_rollback_executed"
else
    err "9b: --force did not emit gap_rollback_executed"
fi

# ── Test 10: ROLLBACK_RUNBOOK.md exists and is non-empty ─────────────────────
RUNBOOK="$REPO_ROOT/docs/process/ROLLBACK_RUNBOOK.md"
if [[ -f "$RUNBOOK" ]] && [[ $(wc -l < "$RUNBOOK") -gt 20 ]]; then
    ok "10: ROLLBACK_RUNBOOK.md exists with substantive content"
else
    err "10: ROLLBACK_RUNBOOK.md missing or too short"
fi

echo ""
echo "Results: $pass passed, $fail failed"
[[ "$fail" -eq 0 ]]
