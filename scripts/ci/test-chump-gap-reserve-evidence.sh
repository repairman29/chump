#!/usr/bin/env bash
# test-chump-gap-reserve-evidence.sh — CREDIBLE-107
#
# Validates the --evidence gate on `chump gap reserve` and
# the --flag-empty-evidence check on `chump gap audit-priorities`.
#
# Test cases:
#  (a) P0 RESILIENT without --evidence → fails with documented message
#  (b) P1 MISSION with --evidence → succeeds and stores evidence
#  (c) P2 RESILIENT without --evidence → succeeds (gate only applies P0/P1)
#  (d) P0 INFRA without --evidence → succeeds (gate only applies RESILIENT/MISSION/CREDIBLE)
#  (e) CHUMP_GAP_RESERVE_NO_EVIDENCE=1 bypasses gate, emits gap_reserved_no_evidence
#  (f) chump gap audit-priorities --flag-empty-evidence lists P0/P1 RESILIENT gaps without evidence

set -euo pipefail

PASS=0
FAIL=0
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

REPO_ROOT="$(git rev-parse --show-toplevel)"

echo "=== CREDIBLE-107 --evidence gate test ==="
echo

# ── Source checks (static, no binary needed) ──────────────────────────────────

if grep -q 'gap_reserved_no_evidence' "$REPO_ROOT/src/main.rs" "$REPO_ROOT/src/commands/dispatch_gap.rs"; then
    ok "gap_reserved_no_evidence emitted in main.rs"
else
    fail "gap_reserved_no_evidence not found in main.rs"
fi

if grep -q 'gap_reserved_no_evidence' "$REPO_ROOT/docs/observability/EVENT_REGISTRY.yaml"; then
    ok "gap_reserved_no_evidence registered in EVENT_REGISTRY.yaml"
else
    fail "gap_reserved_no_evidence missing from EVENT_REGISTRY.yaml"
fi

if grep -q '\-\-evidence' "$REPO_ROOT/src/main.rs" "$REPO_ROOT/src/commands/dispatch_gap.rs"; then
    ok "--evidence flag wired in main.rs"
else
    fail "--evidence flag not found in main.rs"
fi

if grep -q 'CHUMP_GAP_RESERVE_NO_EVIDENCE' "$REPO_ROOT/src/main.rs" "$REPO_ROOT/src/commands/dispatch_gap.rs"; then
    ok "CHUMP_GAP_RESERVE_NO_EVIDENCE bypass env wired in main.rs"
else
    fail "CHUMP_GAP_RESERVE_NO_EVIDENCE env not found in main.rs"
fi

if grep -q 'flag-empty-evidence' "$REPO_ROOT/src/main.rs" "$REPO_ROOT/src/commands/dispatch_gap.rs"; then
    ok "--flag-empty-evidence wired in audit-priorities"
else
    fail "--flag-empty-evidence not found in main.rs"
fi

if grep -q 'pub evidence' "$REPO_ROOT/crates/chump-gap-store/src/lib.rs"; then
    ok "evidence field in GapRow/GapFieldUpdate"
else
    fail "evidence field not found in gap-store lib.rs"
fi

# ── Functional tests ──────────────────────────────────────────────────────────

BIN="${CARGO_TARGET_DIR:-$REPO_ROOT/target}/debug/chump"
if [[ ! -f "$BIN" ]]; then
    echo "  [build] cargo build --bin chump (quiet)..."
    RUSTC_WRAPPER="" cargo build --bin chump --manifest-path "$REPO_ROOT/Cargo.toml" -q 2>&1 | tail -5
fi

if [[ ! -f "$BIN" ]]; then
    fail "chump binary not found after build — skipping functional tests"
    echo
    echo "=== Results: $PASS passed, $FAIL failed ==="
    [[ "$FAIL" -eq 0 ]]
    exit
fi

TMP="$(mktemp -d)"
AMBIENT="$TMP/.chump-locks/ambient.jsonl"
mkdir -p "$TMP/.chump-locks"
trap 'rm -rf "$TMP"' EXIT

export CHUMP_REPO="$TMP"
export CHUMP_HOME="$TMP"
export CHUMP_ALLOW_MAIN_WORKTREE=1
export FLEET_029_AMBIENT_GLANCE_SKIP=1
export CHUMP_RESERVE_NO_AUTOSTAGE=1
export CHUMP_DISABLE_OFFLINE_CHECK=1
export CHUMP_GAP_RESERVE_NO_SIMILARITY=1
export CHUMP_PILLAR_BALANCE_DISABLE=1

# (a) P0 RESILIENT without --evidence → must fail with documented message
echo
echo "--- (a) P0 RESILIENT without --evidence ---"
ERR_OUT=$(
    "$BIN" gap reserve --domain RESILIENT --priority P0 --effort xs \
        --title "test-evidence-gate-a" 2>&1 || true
)
if echo "$ERR_OUT" | grep -q "require --evidence"; then
    ok "(a) gate fires: refused with documented message"
else
    fail "(a) gate did not fire for P0 RESILIENT without --evidence (got: $ERR_OUT)"
fi
# Verify it didn't actually reserve
CNT=$("$BIN" gap list --status open 2>/dev/null | grep -c "test-evidence-gate-a" || true)
if [[ "$CNT" -eq 0 ]]; then
    ok "(a) gap was NOT reserved (gate blocked correctly)"
else
    fail "(a) gap was reserved despite gate (should have been blocked)"
fi

# (b) P1 MISSION with --evidence → succeeds and evidence is stored
echo
echo "--- (b) P1 MISSION with --evidence ---"
EVIDENCE_TEXT="$(printf 'COMMAND: pgrep -f mesh-worker\nOUTPUT: (empty)\nTHEORY: workers not running\nALT: workers running under different name (REFUTED)')"
# Capture ID directly from stdout (reserve prints the ID on stdout)
B_ID=$("$BIN" gap reserve --domain MISSION --priority P1 --effort xs \
    --title "test-evidence-gate-b" \
    --evidence "$EVIDENCE_TEXT" \
    --skip-obs-acs \
    --quiet 2>/dev/null || true)
if [[ -n "$B_ID" ]]; then
    ok "(b) P1 MISSION with --evidence reserved successfully (id=$B_ID)"
else
    fail "(b) P1 MISSION with --evidence failed to reserve"
fi
# Verify evidence stored in DB (shown by gap show)
if [[ -n "$B_ID" ]]; then
    SHOW_OUT=$("$BIN" gap show "$B_ID" 2>/dev/null || true)
    if echo "$SHOW_OUT" | grep -q "COMMAND:"; then
        ok "(b) evidence text stored and shown in gap show"
    else
        fail "(b) evidence not found in gap show output (show=$SHOW_OUT)"
    fi
fi

# (c) P2 RESILIENT without --evidence → succeeds (gate only P0/P1)
echo
echo "--- (c) P2 RESILIENT without --evidence ---"
"$BIN" gap reserve --domain RESILIENT --priority P2 --effort xs \
    --title "test-evidence-gate-c" \
    --skip-obs-acs \
    --quiet 2>/dev/null
CNT=$("$BIN" gap list --status open 2>/dev/null | grep -c "test-evidence-gate-c" || true)
if [[ "$CNT" -ge 1 ]]; then
    ok "(c) P2 RESILIENT without --evidence allowed (gate only applies P0/P1)"
else
    fail "(c) P2 RESILIENT was blocked — gate should not apply to P2"
fi

# (d) P0 INFRA without --evidence → succeeds (gate only RESILIENT/MISSION/CREDIBLE)
echo
echo "--- (d) P0 INFRA without --evidence ---"
"$BIN" gap reserve --domain INFRA --priority P0 --effort xs \
    --title "test-evidence-gate-d" \
    --skip-obs-acs \
    --quiet 2>/dev/null
CNT=$("$BIN" gap list --status open 2>/dev/null | grep -c "test-evidence-gate-d" || true)
if [[ "$CNT" -ge 1 ]]; then
    ok "(d) P0 INFRA without --evidence allowed (gate only applies to substrate domains)"
else
    fail "(d) P0 INFRA was blocked — gate should not apply to INFRA domain"
fi

# (e) CHUMP_GAP_RESERVE_NO_EVIDENCE=1 bypass → succeeds, emits gap_reserved_no_evidence
echo
echo "--- (e) bypass via CHUMP_GAP_RESERVE_NO_EVIDENCE=1 ---"
CHUMP_GAP_RESERVE_NO_EVIDENCE=1 "$BIN" gap reserve --domain RESILIENT --priority P0 --effort xs \
    --title "test-evidence-gate-e" \
    --skip-obs-acs \
    --quiet 2>/dev/null
CNT=$("$BIN" gap list --status open 2>/dev/null | grep -c "test-evidence-gate-e" || true)
if [[ "$CNT" -ge 1 ]]; then
    ok "(e) bypass via env var succeeded — gap reserved"
else
    fail "(e) bypass via CHUMP_GAP_RESERVE_NO_EVIDENCE=1 did not reserve gap"
fi
if [[ -f "$AMBIENT" ]] && grep -q "gap_reserved_no_evidence" "$AMBIENT"; then
    ok "(e) gap_reserved_no_evidence event emitted to ambient.jsonl"
else
    fail "(e) gap_reserved_no_evidence event NOT found in ambient.jsonl"
fi

# (f) chump gap audit-priorities --flag-empty-evidence lists P0/P1 substrate gaps missing evidence
echo
echo "--- (f) audit-priorities --flag-empty-evidence ---"
AUDIT_OUT=$("$BIN" gap audit-priorities --flag-empty-evidence 2>/dev/null || true)
# The P0 RESILIENT gap from (e) has no evidence — it should appear
if echo "$AUDIT_OUT" | grep -q "Missing evidence\|missing evidence\|RESILIENT/MISSION/CREDIBLE"; then
    ok "(f) --flag-empty-evidence section rendered in audit output"
else
    fail "(f) --flag-empty-evidence section not found in audit output (got: $AUDIT_OUT)"
fi
# Verify JSON mode also has the key
JSON_OUT=$("$BIN" gap audit-priorities --json 2>/dev/null || true)
if echo "$JSON_OUT" | grep -q '"missing_evidence_count"'; then
    ok "(f) missing_evidence_count key present in JSON output"
else
    fail "(f) missing_evidence_count key missing from JSON output"
fi
ME_COUNT=$(echo "$JSON_OUT" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('missing_evidence_count',0))" 2>/dev/null || echo 0)
if [[ "$ME_COUNT" -ge 1 ]]; then
    ok "(f) missing_evidence_count >= 1 (got $ME_COUNT — P0 RESILIENT from bypass)"
else
    fail "(f) missing_evidence_count should be >= 1 (got $ME_COUNT)"
fi

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
