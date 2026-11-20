#!/usr/bin/env bash
# scripts/ci/test-escalation-tier.sh — INFRA-1890
#
# Seeds a synthetic ambient.jsonl with 10x the same kind=gap_failed
# signature spanning 12h, runs scripts/coord/escalation-tier.sh against it
# with a stubbed `chump` binary on PATH, and asserts:
#   1. exactly one gap is filed (kind=escalation_fired, gap_id_filed=TEST-9001)
#   2. a second run against the same state sees kind=escalation_dedup_hit,
#      NOT a second filing.
#
# Network-free: `chump gap show` / `gap reserve` / `gap list` and `git log`
# are all stubbed or point at a throwaway repo so CI never touches a real
# gap store.

set -uo pipefail

PASS=0
FAIL=0
FAILS=()
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); FAILS+=("$1"); }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TARGET="$REPO_ROOT/scripts/coord/escalation-tier.sh"

[[ -x "$TARGET" ]] || { echo "FAIL: $TARGET not executable"; exit 1; }

echo "=== INFRA-1890 escalation-tier tests ==="

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

STATE_DIR="$TMP/state"
AMB="$TMP/ambient.jsonl"
STUB_BIN_DIR="$TMP/bin"
STUB_CALL_LOG="$TMP/chump-reserve-calls.log"
mkdir -p "$STATE_DIR" "$STUB_BIN_DIR"
: > "$STUB_CALL_LOG"

# ── Stub `chump` on PATH ─────────────────────────────────────────────────
# gap show TEST-9001    -> status: open (so rule (a) recovery-check passes)
# gap list --status open --grep ... -> empty (no existing dup) on 1st call;
#   we detect "already filed" via the SEEN_FILE local dedup gate instead,
#   which is the fast-path INFRA-1890 AC3 describes, so the stub can stay
#   dumb and always report no matches.
# gap reserve ...       -> prints "TEST-9001" (fake filed gap id)
cat > "$STUB_BIN_DIR/chump" <<'STUB'
#!/usr/bin/env bash
if [[ "$1" == "gap" && "$2" == "show" ]]; then
    echo "id: $3"
    echo "status: open"
    exit 0
fi
if [[ "$1" == "gap" && "$2" == "list" ]]; then
    # No pre-existing open gaps in this fixture — always empty.
    exit 0
fi
if [[ "$1" == "gap" && "$2" == "reserve" ]]; then
    echo "$*" >> "$STUB_CALL_LOG"
    echo "reserved TEST-9001"
    exit 0
fi
exit 0
STUB
chmod +x "$STUB_BIN_DIR/chump"

# Seed 10x kind=gap_failed for the same gap_id spanning 12h (well within
# the default 24h window), oldest first.
python3 -c "
import datetime, json
now = datetime.datetime.utcnow()
lines = []
for i in range(10):
    ts = now - datetime.timedelta(hours=12) + datetime.timedelta(minutes=i*70)
    lines.append(json.dumps({
        'ts': ts.strftime('%Y-%m-%dT%H:%M:%SZ'),
        'kind': 'gap_failed',
        'gap_id': 'TEST-9001',
        'class': 'stuck_lease',
        'reason': 'no commit in 2h',
    }))
open('$AMB', 'w').write('\n'.join(lines) + '\n')
"

run_escalation() {
    env \
        PATH="$STUB_BIN_DIR:$PATH" \
        CHUMP_BIN="$STUB_BIN_DIR/chump" \
        CHUMP_REPO="$REPO_ROOT" \
        CHUMP_AMBIENT_LOG="$AMB" \
        CHUMP_ESCALATION_STATE_DIR="$STATE_DIR" \
        STUB_CALL_LOG="$STUB_CALL_LOG" \
        bash "$TARGET" 2>&1
}

# ── Run 1: expect exactly one filing ─────────────────────────────────────
out1="$(run_escalation)"
fired_count="$(grep -c '"kind":"escalation_fired"' "$AMB" || true)"
if [[ "$fired_count" -eq 1 ]]; then
    ok "run 1: exactly one escalation_fired event"
else
    fail "run 1: expected 1 escalation_fired event, got $fired_count (out: $out1)"
fi

if grep -q '"gap_id_filed":"TEST-9001"' "$AMB"; then
    ok "run 1: filed gap references stubbed TEST-9001"
else
    fail "run 1: escalation_fired event missing expected gap_id_filed"
fi

if grep -qi "RESILIENT: TEST-9001 stuck" "$STUB_CALL_LOG"; then
    ok "run 1: gap title follows the AC template"
else
    fail "run 1: gap title did not follow the 'RESILIENT: <gap-id> stuck' template (reserve calls: $(cat "$STUB_CALL_LOG"))"
fi

# ── Run 2: same state, expect dedup_hit, no second filing ───────────────
out2="$(run_escalation)"
fired_count_2="$(grep -c '"kind":"escalation_fired"' "$AMB" || true)"
dedup_count="$(grep -c '"kind":"escalation_dedup_hit"' "$AMB" || true)"

if [[ "$fired_count_2" -eq 1 ]]; then
    ok "run 2: still exactly one escalation_fired event total (no re-filing)"
else
    fail "run 2: expected total escalation_fired to stay at 1, got $fired_count_2 (out: $out2)"
fi

if [[ "$dedup_count" -ge 1 ]]; then
    ok "run 2: escalation_dedup_hit emitted on second run"
else
    fail "run 2: expected escalation_dedup_hit, none found (out: $out2)"
fi

echo ""
echo "=== $PASS passed, $FAIL failed ==="
if [[ $FAIL -gt 0 ]]; then
    printf 'FAILURES:\n'
    printf '  - %s\n' "${FAILS[@]}"
    exit 1
fi
exit 0
