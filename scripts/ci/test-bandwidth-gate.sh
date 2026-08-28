#!/usr/bin/env bash
# scripts/ci/test-bandwidth-gate.sh — INFRA-1804
#
# Verifies the BandwidthBudget-backed compatibility shim wired into the
# chump_gh self-throttle (scripts/coord/lib/github.sh
# _chump_gh_bandwidth_gate_check / _chump_gh_preempt_if_low):
#   1. chump-bandwidth-gate CLI: critical calls always proceed (exit 0, no
#      state file write)
#   2. chump-bandwidth-gate CLI: background calls deduct from the budget
#      and exit 1 once the per-window cap is exhausted
#   3. chump-bandwidth-gate CLI: window resets after window_seconds elapse
#   4. _chump_gh_bandwidth_gate_check is a no-op unless
#      CHUMP_BANDWIDTH_GATE_RUST=1 (compatibility default: off)
#   5. When enabled and the budget is exhausted, the shell layer emits
#      kind=gh_preempted to ambient.jsonl

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
LIB="$REPO_ROOT/scripts/coord/lib/github.sh"

ok()   { printf '\033[0;32mPASS\033[0m %s\n' "$*"; }
fail() { printf '\033[0;31mFAIL\033[0m %s\n' "$*"; exit 1; }

command -v cargo >/dev/null 2>&1 || { echo "SKIP: no cargo on PATH"; exit 0; }

BIN_DIR="$REPO_ROOT/target/debug"
(cd "$REPO_ROOT" && cargo build -q -p chump-coord --bin chump-bandwidth-gate) || {
    echo "SKIP: cargo build failed for chump-bandwidth-gate"
    exit 0
}
GATE_BIN="$BIN_DIR/chump-bandwidth-gate"
[[ -x "$GATE_BIN" ]] || { echo "SKIP: $GATE_BIN missing after build"; exit 0; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# ── Test 1: critical calls always proceed, no state file ────────────────────
STATE="$TMP/critical.json"
"$GATE_BIN" --state-file "$STATE" --max-calls-per-min 1 --criticality critical \
    || fail "critical call should always exit 0"
[[ -f "$STATE" ]] && fail "critical call should not write state"
ok "critical criticality always proceeds, no state written"

# ── Test 2: background calls drain the budget then defer ────────────────────
STATE="$TMP/bg.json"
"$GATE_BIN" --state-file "$STATE" --max-calls-per-min 2 --criticality background \
    || fail "1st background call (budget 2) should proceed"
"$GATE_BIN" --state-file "$STATE" --max-calls-per-min 2 --criticality background \
    || fail "2nd background call (budget 2) should proceed"
if "$GATE_BIN" --state-file "$STATE" --max-calls-per-min 2 --criticality background; then
    fail "3rd background call should be deferred (budget exhausted)"
fi
[[ -f "$STATE" ]] || fail "background call should persist state"
ok "background calls deduct from BandwidthBudget and defer once exhausted"

# ── Test 3: window resets after window_seconds elapse ───────────────────────
STATE="$TMP/reset.json"
python3 - "$STATE" <<'PY'
import json, sys, datetime
path = sys.argv[1]
stale_start = (datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(seconds=120)).isoformat()
json.dump({"remaining": 0, "total": 1, "window_seconds": 60, "window_start": stale_start}, open(path, "w"))
PY
"$GATE_BIN" --state-file "$STATE" --max-calls-per-min 1 --criticality background \
    || fail "expired window should reset and allow the call through"
ok "expired window resets remaining budget"

# ── Test 4: shell shim is a no-op unless CHUMP_BANDWIDTH_GATE_RUST=1 ────────
export CHUMP_AMBIENT_OVERRIDE="$TMP/ambient.jsonl"
export PATH="$BIN_DIR:$PATH"
# shellcheck disable=SC1090
source "$LIB"
rm -f "$CHUMP_AMBIENT_OVERRIDE"
CHUMP_GH_MAX_CALLS_PER_MIN=0 _chump_gh_bandwidth_gate_check "test-harness" "api/x" \
    || fail "gate check should return 0 by default (opt-in flag unset)"
[[ -f "$CHUMP_AMBIENT_OVERRIDE" ]] && fail "no ambient event expected when CHUMP_BANDWIDTH_GATE_RUST unset"
ok "compatibility shim: no-op unless CHUMP_BANDWIDTH_GATE_RUST=1"

# ── Test 5: enabled + exhausted budget emits gh_preempted ───────────────────
rm -f "$CHUMP_AMBIENT_OVERRIDE"
STATE_DIR="$(dirname "$CHUMP_AMBIENT_OVERRIDE")"
STATE_FILE="$STATE_DIR/.gh-bandwidth-budget.test-harness.json"
mkdir -p "$STATE_DIR"
python3 - "$STATE_FILE" <<'PY'
import json, sys, datetime
path = sys.argv[1]
now = datetime.datetime.now(datetime.timezone.utc).isoformat()
json.dump({"remaining": 0, "total": 1, "window_seconds": 60, "window_start": now}, open(path, "w"))
PY
CHUMP_BANDWIDTH_GATE_RUST=1 CHUMP_GH_MAX_CALLS_PER_MIN=1 \
    _chump_gh_bandwidth_gate_check "test-harness" "api/x"
grep -q '"kind":"gh_preempted"' "$CHUMP_AMBIENT_OVERRIDE" \
    || fail "expected gh_preempted event: $(cat "$CHUMP_AMBIENT_OVERRIDE" 2>/dev/null)"
ok "CHUMP_BANDWIDTH_GATE_RUST=1 + exhausted budget emits gh_preempted"

echo
echo "All INFRA-1804 bandwidth-gate tests passed."
