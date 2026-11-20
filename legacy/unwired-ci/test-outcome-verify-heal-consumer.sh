#!/usr/bin/env bash
# scripts/ci/test-outcome-verify-heal-consumer.sh — INFRA-3654 (PEER-VERI-07)
#
# Proves outcome-verify-heal-consumer.sh holds/reopens the named gap AND
# pages the duty officer (via notify-operator's escalation gate — verified
# through the operator_paged ambient event, since DISCORD_TOKEN/
# CHUMP_READY_DM_USER_ID are unset in CI and notify_operator no-ops after
# the paging decision) exactly once per (kind, gap) within the dedup window,
# using a synthetic ambient.jsonl and a stubbed `chump` binary — no real gap
# store, no real Discord call.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

CONSUMER="$REPO_ROOT/scripts/coord/outcome-verify-heal-consumer.sh"

pass() { echo "  ✓ $*"; }
fail() { echo "  ✗ $*" >&2; exit 1; }

echo "=== test-outcome-verify-heal-consumer.sh (INFRA-3654) ==="

# ── 1. Source contract ───────────────────────────────────────────────────────
[[ -f "$CONSUMER" ]] || fail "consumer script missing: $CONSUMER"
[[ -x "$CONSUMER" ]] || fail "consumer script not executable: $CONSUMER"
bash -n "$CONSUMER" || fail "consumer script bash -n failed"
pass "script present, syntax clean"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Stub `chump` binary — records every invocation so we can assert on the
# gap-set call shape (AC1: hold/reopen).
FAKE_GAP_BIN="$TMP/fake-chump"
GAP_CALLS="$TMP/gap-calls.log"
cat > "$FAKE_GAP_BIN" <<EOF
#!/usr/bin/env bash
echo "\$@" >> "$GAP_CALLS"
exit 0
EOF
chmod +x "$FAKE_GAP_BIN"

AMBIENT="$TMP/ambient.jsonl"
STATE_DIR="$TMP/state"

# ── 2. Inject a synthetic outcome_probe_failed event ────────────────────────
cat > "$AMBIENT" <<'EOF'
{"ts":"2026-08-22T00:00:00Z","kind":"some_unrelated_event"}
{"ts":"2026-08-22T00:00:01Z","kind":"outcome_probe_failed","pr":"9001","repo":"repairman29/chump","gap":"INFRA-9999","url":"https://example.invalid","note":"substring not found"}
EOF

REPO_ROOT="$REPO_ROOT" \
CHUMP_OUTCOME_VERIFY_STATE_DIR="$STATE_DIR" \
CHUMP_OUTCOME_VERIFY_GAP_BIN="$FAKE_GAP_BIN" \
    bash "$CONSUMER" --ambient-log "$AMBIENT" > "$TMP/out1.log" 2>&1
rc=$?
[[ $rc -eq 0 ]] || fail "consumer exited $rc (expected 0): $(cat "$TMP/out1.log")"
pass "consumer ran clean on injected outcome_probe_failed event"

# ── 3. Gap was held/reopened exactly once ───────────────────────────────────
[[ -f "$GAP_CALLS" ]] || fail "chump gap set was never invoked (AC1)"
grep -q '^gap set INFRA-9999 --status open --add-note' "$GAP_CALLS" \
    || fail "gap set call shape wrong: $(cat "$GAP_CALLS")"
[[ "$(wc -l < "$GAP_CALLS" | tr -d ' ')" == "1" ]] \
    || fail "expected exactly 1 gap-set call, got: $(cat "$GAP_CALLS")"
pass "gap INFRA-9999 held/reopened exactly once (AC1, AC3)"

# ── 4. Duty officer was paged exactly once (operator_paged ambient event) ──
paged_count="$(grep -c '"kind":"operator_paged"' "$AMBIENT" || true)"
[[ "$paged_count" == "1" ]] || fail "expected exactly 1 operator_paged event, got $paged_count"
grep -q '"signal":"outcome_probe_failed"' "$AMBIENT" \
    || fail "operator_paged event missing signal=outcome_probe_failed"
pass "notify-operator call fired exactly once (AC1, AC4 PROOF)"

grep -q '"kind":"outcome_verify_heal_consumer_held"' "$AMBIENT" \
    || fail "outcome_verify_heal_consumer_held not emitted"
grep -q '"kind":"outcome_verify_heal_consumer_tick"' "$AMBIENT" \
    || fail "outcome_verify_heal_consumer_tick heartbeat not emitted"
pass "consumer-owned ambient events present"

# ── 5. Idempotent within the dedup window (AC3) ─────────────────────────────
# Same event still sitting at the same offset would not be reprocessed (the
# cursor already advanced past it) — append a FRESH sighting of the SAME
# (kind, gap) pair and confirm it is dedup-skipped, not re-held/re-paged.
cat >> "$AMBIENT" <<'EOF'
{"ts":"2026-08-22T00:05:00Z","kind":"outcome_probe_failed","pr":"9001","repo":"repairman29/chump","gap":"INFRA-9999","url":"https://example.invalid","note":"still not found"}
EOF

REPO_ROOT="$REPO_ROOT" \
CHUMP_OUTCOME_VERIFY_STATE_DIR="$STATE_DIR" \
CHUMP_OUTCOME_VERIFY_GAP_BIN="$FAKE_GAP_BIN" \
CHUMP_OUTCOME_VERIFY_DEDUP_WINDOW_S=3600 \
    bash "$CONSUMER" --ambient-log "$AMBIENT" > "$TMP/out2.log" 2>&1
rc=$?
[[ $rc -eq 0 ]] || fail "consumer exited $rc on second pass (expected 0)"

[[ "$(wc -l < "$GAP_CALLS" | tr -d ' ')" == "1" ]] \
    || fail "dedup window should have suppressed the 2nd gap-set call, got: $(cat "$GAP_CALLS")"
paged_count2="$(grep -c '"kind":"operator_paged"' "$AMBIENT" || true)"
[[ "$paged_count2" == "1" ]] \
    || fail "dedup window should have suppressed the 2nd page, got $paged_count2 total"
grep -q '"kind":"outcome_verify_heal_consumer_dedup_skip"' "$AMBIENT" \
    || fail "outcome_verify_heal_consumer_dedup_skip not emitted on repeat sighting"
pass "repeat sighting within dedup window suppressed (exactly one page/hold total, AC3)"

# ── 6. ac_coverage_proof_miss uses the gap_id field name ────────────────────
AMBIENT2="$TMP/ambient2.jsonl"
STATE_DIR2="$TMP/state2"
GAP_CALLS2="$TMP/gap-calls2.log"
FAKE_GAP_BIN2="$TMP/fake-chump2"
cat > "$FAKE_GAP_BIN2" <<EOF
#!/usr/bin/env bash
echo "\$@" >> "$GAP_CALLS2"
exit 0
EOF
chmod +x "$FAKE_GAP_BIN2"
cat > "$AMBIENT2" <<'EOF'
{"ts":"2026-08-22T00:00:00Z","kind":"ac_coverage_proof_miss","pr_number":"9002","gap_id":"CREDIBLE-8888","bullet_index":"0","detail":"no live-outcome target named"}
EOF

REPO_ROOT="$REPO_ROOT" \
CHUMP_OUTCOME_VERIFY_STATE_DIR="$STATE_DIR2" \
CHUMP_OUTCOME_VERIFY_GAP_BIN="$FAKE_GAP_BIN2" \
    bash "$CONSUMER" --ambient-log "$AMBIENT2" > "$TMP/out3.log" 2>&1
rc=$?
[[ $rc -eq 0 ]] || fail "consumer exited $rc on ac_coverage_proof_miss event (expected 0)"
grep -q '^gap set CREDIBLE-8888 --status open --add-note' "$GAP_CALLS2" \
    || fail "gap_id field not used for ac_coverage_proof_miss: $(cat "$GAP_CALLS2" 2>/dev/null || echo MISSING)"
pass "ac_coverage_proof_miss (gap_id field) also held/reopened (AC1)"

# ── 7. Organ-watchdog visibility (AC2) ──────────────────────────────────────
[[ -f "$REPO_ROOT/scripts/dispatch/chump-outcome-verify-heal-consumer.service" ]] \
    || fail "chump-outcome-verify-heal-consumer.service missing (AC2)"
[[ -f "$REPO_ROOT/scripts/dispatch/chump-outcome-verify-heal-consumer.timer" ]] \
    || fail "chump-outcome-verify-heal-consumer.timer missing (AC2)"
grep -qE '^enabled\s+chump-outcome-verify-heal-consumer\.timer' \
    "$REPO_ROOT/scripts/ops/organ-manifest.txt" \
    || fail "chump-outcome-verify-heal-consumer.timer not declared 'enabled' in organ-manifest.txt (AC2, Roll-Call)"
pass "tracked systemd unit + organ-manifest.txt Roll-Call entry present"

grep -qE '^\s*outcome-verify-heal-consumer\)' "$REPO_ROOT/scripts/ops/reaper-heartbeat-watchdog.sh" \
    || fail "reaper-heartbeat-watchdog.sh has no outcome-verify-heal-consumer threshold case (AC2)"
grep -qE 'TARGETS=\(.*outcome-verify-heal-consumer' "$REPO_ROOT/scripts/ops/reaper-heartbeat-watchdog.sh" \
    || fail "outcome-verify-heal-consumer not in reaper-heartbeat-watchdog.sh's default TARGETS (AC2)"
pass "reaper-heartbeat-watchdog.sh grades outcome-verify-heal-consumer"

echo "=== all outcome-verify-heal-consumer tests passed ==="
