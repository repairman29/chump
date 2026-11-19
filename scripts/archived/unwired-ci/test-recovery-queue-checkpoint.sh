#!/usr/bin/env bash
# scripts/ci/test-recovery-queue-checkpoint.sh — INFRA-2027
#
# Validates the mid-flight checkpoint + auto-restore behaviour added in INFRA-2027.
#
# Test cases:
#   1. Fresh checkpoint (age < threshold) → daemon does NOT restore (process may still live)
#   2. Orphaned checkpoint at "drop" step with valid backup → daemon restores ruleset
#      + emits operator_recovery_aborted_recovered
#   3. Orphaned checkpoint at "snapshot" step (died before drop) → ruleset intact;
#      daemon emits operator_recovery_aborted_recovered with died_before_drop note
#   4. Orphaned checkpoint at "merge" step → daemon restores + emits event
#   5. Checkpoint missing backup file → checkpoint cleared without restore attempt
#   6. No checkpoint present → daemon starts normally, no recovery events emitted
#   7. Successful cycle → checkpoint file is cleared after completion

set -uo pipefail

PASS=0
FAIL=0
FAILS=()

ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); FAILS+=("$1"); }

echo "=== INFRA-2027 recovery-queue checkpoint tests ==="
echo

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
SERVICE="$REPO_ROOT/scripts/coord/recovery-queue-service.sh"

[[ -x "$SERVICE" ]] || { echo "FATAL: $SERVICE not executable"; exit 2; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

FAKE="$TMP/repo"
mkdir -p "$FAKE/.chump-locks"

# ── Shared mock gh ──────────────────────────────────────────────────────────
mkdir -p "$TMP/bin"
cat > "$TMP/bin/gh" <<'GH'
#!/usr/bin/env bash
echo "$@" >> "${GH_CALL_LOG:-/dev/null}"
case "$1 $2" in
    "api repos/{owner}/{repo}/rulesets/15133729"|"api repos/repairman29/chump/rulesets/15133729")
        echo '{"id":15133729,"name":"Protect main","target":"branch","enforcement":"active","conditions":{"ref_name":{"exclude":[],"include":["~DEFAULT_BRANCH"]}},"rules":[{"type":"deletion"},{"type":"required_status_checks","parameters":{"required_status_checks":[{"context":"test"}]}}]}'
        exit 0
        ;;
    "api -X")
        exit 0
        ;;
    "pr merge")
        exit 0
        ;;
    "pr view")
        echo "MERGED"
        exit 0
        ;;
esac
exit 0
GH
chmod +x "$TMP/bin/gh"

run_service() {
    cd "$FAKE" || return 2
    env \
        CHUMP_REPO="$FAKE" \
        CHUMP_AMBIENT_LOG="$FAKE/.chump-locks/ambient.jsonl" \
        CHUMP_RECOVERY_QUEUE_TEST_GH="$TMP/bin/gh" \
        GH_CALL_LOG="$TMP/gh-calls.log" \
        CHUMP_RECOVERY_QUEUE_CHECKPOINT_MAX_AGE=60 \
        "$@" \
        bash "$SERVICE" 2>&1
    RC=$?
    cd - >/dev/null
    return "$RC"
}

# Helper: write a checkpoint file with a given step, backup path, and age offset
write_checkpoint() {
    local step="$1"
    local backup_path="${2:-}"
    local age_offset="${3:-300}"   # seconds in the past (default 5 min → stale)
    local ts
    ts="$(python3 -c "
import datetime
now = datetime.datetime.now(datetime.timezone.utc)
import datetime as dt
past = now - dt.timedelta(seconds=$age_offset)
print(past.strftime('%Y-%m-%dT%H:%M:%SZ'))
")"
    printf '{"step":"%s","backup_path":"%s","started_ts":"%s","pid":99999}\n' \
        "$step" "$backup_path" "$ts" \
        > "$FAKE/.chump-locks/recovery-queue-in-flight.json"
}

# Synthetic backup content
SYNTHETIC_RULESET='{"id":15133729,"name":"Protect main","target":"branch","enforcement":"active","conditions":{"ref_name":{"exclude":[],"include":["~DEFAULT_BRANCH"]}},"rules":[{"type":"deletion"},{"type":"required_status_checks","parameters":{"required_status_checks":[{"context":"test"}]}}]}'

# ── Test 1: Fresh checkpoint → no auto-restore ──────────────────────────────
echo "--- Test 1: fresh checkpoint (age < threshold) → no restore ---"
> "$FAKE/.chump-locks/ambient.jsonl"
> "$TMP/gh-calls.log"
# Write a checkpoint timestamped 5 seconds ago (well within 60s threshold)
write_checkpoint "drop" "/tmp/some-backup.json" 5
run_service > /dev/null 2>&1
if grep -q "operator_recovery_aborted_recovered" "$FAKE/.chump-locks/ambient.jsonl" 2>/dev/null; then
    fail "fresh checkpoint should NOT trigger auto-restore"
else
    ok "fresh checkpoint: no restore attempted"
fi

# ── Test 2: Orphaned checkpoint at "drop" step with valid backup → restore ──
echo "--- Test 2: orphaned checkpoint at 'drop' step → ruleset restored + event emitted ---"
> "$FAKE/.chump-locks/ambient.jsonl"
> "$TMP/gh-calls.log"
BACKUP_FILE="$TMP/synthetic-backup.json"
echo "$SYNTHETIC_RULESET" > "$BACKUP_FILE"
write_checkpoint "drop" "$BACKUP_FILE" 300   # 5 min old → stale
run_service > /dev/null 2>&1
if grep -q "operator_recovery_aborted_recovered" "$FAKE/.chump-locks/ambient.jsonl" 2>/dev/null \
   && grep -q '"aborted_step":"drop"' "$FAKE/.chump-locks/ambient.jsonl" 2>/dev/null \
   && grep -q "api -X PUT" "$TMP/gh-calls.log" 2>/dev/null; then
    ok "drop-step orphan: ruleset restored + event emitted"
else
    fail "drop-step orphan: expected restore + event (ambient=$(cat "$FAKE/.chump-locks/ambient.jsonl"), gh=$(cat "$TMP/gh-calls.log"))"
fi

# Checkpoint file should be cleared
if [[ ! -f "$FAKE/.chump-locks/recovery-queue-in-flight.json" ]]; then
    ok "checkpoint file cleared after auto-restore"
else
    fail "checkpoint file not cleared after auto-restore"
fi

# ── Test 3: Orphaned checkpoint at "snapshot" step → no restore needed ──────
echo "--- Test 3: orphaned checkpoint at 'snapshot' step → event emitted, no PUT ---"
> "$FAKE/.chump-locks/ambient.jsonl"
> "$TMP/gh-calls.log"
write_checkpoint "snapshot" "/tmp/not-yet-written.json" 300
run_service > /dev/null 2>&1
if grep -q "operator_recovery_aborted_recovered" "$FAKE/.chump-locks/ambient.jsonl" 2>/dev/null \
   && grep -q "died_before_drop_no_restore_needed" "$FAKE/.chump-locks/ambient.jsonl" 2>/dev/null; then
    ok "snapshot-step orphan: event emitted with died_before_drop note"
else
    fail "snapshot-step orphan: expected event with died_before_drop note (ambient=$(cat "$FAKE/.chump-locks/ambient.jsonl"))"
fi
# Should NOT have called PUT (ruleset was never dropped)
if grep -q "api -X PUT" "$TMP/gh-calls.log" 2>/dev/null; then
    fail "snapshot-step orphan: unexpected PUT call (ruleset was never dropped)"
else
    ok "snapshot-step orphan: no PUT issued (correct — ruleset was intact)"
fi

# ── Test 4: Orphaned checkpoint at "merge" step → restore ───────────────────
echo "--- Test 4: orphaned checkpoint at 'merge' step → ruleset restored ---"
> "$FAKE/.chump-locks/ambient.jsonl"
> "$TMP/gh-calls.log"
BACKUP_FILE2="$TMP/synthetic-backup2.json"
echo "$SYNTHETIC_RULESET" > "$BACKUP_FILE2"
write_checkpoint "merge" "$BACKUP_FILE2" 300
run_service > /dev/null 2>&1
if grep -q "operator_recovery_aborted_recovered" "$FAKE/.chump-locks/ambient.jsonl" 2>/dev/null \
   && grep -q '"aborted_step":"merge"' "$FAKE/.chump-locks/ambient.jsonl" 2>/dev/null \
   && grep -q "api -X PUT" "$TMP/gh-calls.log" 2>/dev/null; then
    ok "merge-step orphan: ruleset restored + event emitted"
else
    fail "merge-step orphan: expected restore + event (ambient=$(cat "$FAKE/.chump-locks/ambient.jsonl"), gh=$(cat "$TMP/gh-calls.log"))"
fi

# ── Test 5: Orphaned checkpoint with missing backup file → cleared silently ──
echo "--- Test 5: orphaned checkpoint with missing backup file → cleared without restore ---"
> "$FAKE/.chump-locks/ambient.jsonl"
> "$TMP/gh-calls.log"
write_checkpoint "drop" "/tmp/nonexistent-backup-$$$.json" 300
run_service > /dev/null 2>&1
# Should NOT emit a recovery event (no backup to restore from)
if grep -q "operator_recovery_aborted_recovered" "$FAKE/.chump-locks/ambient.jsonl" 2>/dev/null; then
    fail "missing backup: unexpected recovery event emitted"
else
    ok "missing backup: no recovery event (correct — nothing to restore)"
fi
# Checkpoint should still be cleared
if [[ ! -f "$FAKE/.chump-locks/recovery-queue-in-flight.json" ]]; then
    ok "missing backup: stale checkpoint cleared"
else
    fail "missing backup: checkpoint not cleared"
fi

# ── Test 6: No checkpoint → normal startup, no recovery events ──────────────
echo "--- Test 6: no checkpoint file → normal startup, no recovery events ---"
> "$FAKE/.chump-locks/ambient.jsonl"
rm -f "$FAKE/.chump-locks/recovery-queue-in-flight.json"
run_service > /dev/null 2>&1
if grep -q "operator_recovery_aborted_recovered" "$FAKE/.chump-locks/ambient.jsonl" 2>/dev/null; then
    fail "no checkpoint: unexpected recovery event"
else
    ok "no checkpoint: clean startup with no recovery events"
fi

# ── Test 7: Successful cycle → checkpoint cleared ───────────────────────────
echo "--- Test 7: successful cycle → checkpoint file is cleared after completion ---"
> "$FAKE/.chump-locks/ambient.jsonl"
> "$TMP/gh-calls.log"
rm -f "$FAKE/.chump-locks/recovery-queue-state.json" \
      "$FAKE/.chump-locks/recovery-queue-in-flight.json"

# Emit a real recovery request so the service runs a cycle
CHUMP_REPO="$FAKE" \
CHUMP_AMBIENT_LOG="$FAKE/.chump-locks/ambient.jsonl" \
    bash "$REPO_ROOT/scripts/coord/recovery-queue-emit.sh" \
    --prs 8888 --reason "checkpoint-test" > /dev/null 2>&1

run_service > /dev/null 2>&1

if [[ ! -f "$FAKE/.chump-locks/recovery-queue-in-flight.json" ]]; then
    ok "successful cycle: checkpoint file cleared"
else
    CKPT_CONTENT="$(cat "$FAKE/.chump-locks/recovery-queue-in-flight.json")"
    fail "successful cycle: checkpoint file not cleared (content=$CKPT_CONTENT)"
fi
if grep -q "operator_recovery_executed" "$FAKE/.chump-locks/ambient.jsonl" 2>/dev/null; then
    ok "successful cycle: operator_recovery_executed event emitted"
else
    fail "successful cycle: operator_recovery_executed event missing (ambient=$(cat "$FAKE/.chump-locks/ambient.jsonl"))"
fi

# ── Summary ───────────────────────────────────────────────────────────────
echo
echo "=== Results: $PASS passed, $FAIL failed ==="
if [[ "$FAIL" -gt 0 ]]; then
    for f in "${FAILS[@]}"; do echo "  - $f"; done
    exit 1
fi
exit 0
