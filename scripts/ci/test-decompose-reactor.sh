#!/usr/bin/env bash
# scripts/ci/test-decompose-reactor.sh — META-168 Phase 1.5 reactor tests.
#
# AC: stub up 3 FEEDBACK proposals (vague, well-formed, with existing sub-gaps);
# assert 3 votes with correct +1/-1/0 (skip for sub-gaps) reasoning.
#
# Uses a synthetic workspace (temp dir with fake ambient.jsonl + inbox) so
# no live chump state is mutated. The test monkeypatches `chump` via PATH
# with a minimal stub that returns controlled gap JSON.
#
# Exit 0 = all assertions pass. Exit 1 = failure.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DECOMPOSE_LOOP="$REPO_ROOT/scripts/coord/decompose-loop.sh"

pass=0
fail=0

_pass() { echo "  PASS: $*"; (( pass++ )) || true; }
_fail() { echo "  FAIL: $*" >&2; (( fail++ )) || true; }

assert_contains() {
    local label="$1" needle="$2" haystack="$3"
    if printf '%s' "$haystack" | grep -qF "$needle"; then
        _pass "$label"
    else
        _fail "$label — expected to find: '$needle' in output"
        printf '  --- actual output ---\n%s\n  ---\n' "$haystack" >&2
    fi
}

assert_not_contains() {
    local label="$1" needle="$2" haystack="$3"
    if ! printf '%s' "$haystack" | grep -qF "$needle"; then
        _pass "$label"
    else
        _fail "$label — expected NOT to find: '$needle' in output"
    fi
}

# ── synthetic workspace ───────────────────────────────────────────────────

WORK="$(mktemp -d /tmp/test-decompose-reactor.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

LOCK_DIR="$WORK/.chump-locks"
INBOX_DIR="$LOCK_DIR/inbox"
AMBIENT="$LOCK_DIR/ambient.jsonl"
SESSION_ID="test-decompose-session-$$"

mkdir -p "$INBOX_DIR"
touch "$AMBIENT"

# ── chump stub ────────────────────────────────────────────────────────────
# Provides `chump gap show <ID> --json` and `chump vote` responses.
# Controlled via files in $WORK/gap-stubs/<ID>.json

STUB_DIR="$WORK/gap-stubs"
mkdir -p "$STUB_DIR"

CHUMP_STUB="$WORK/bin/chump"
mkdir -p "$WORK/bin"
cat > "$CHUMP_STUB" << 'STUBEOF'
#!/usr/bin/env bash
# Minimal chump stub for test-decompose-reactor.sh
STUB_DIR="${CHUMP_TEST_STUB_DIR:-/tmp/no-stubs}"
LOG_FILE="${CHUMP_TEST_LOG:-/tmp/chump-stub.log}"

sub="${1:-}"
case "$sub" in
    gap)
        sub2="${2:-}"
        case "$sub2" in
            show)
                gap_id="${3:-}"
                flags=("${@:4}")
                stub_file="$STUB_DIR/$gap_id.json"
                if [[ -f "$stub_file" ]]; then
                    cat "$stub_file"
                    exit 0
                else
                    echo "gap $gap_id not found" >&2
                    exit 1
                fi
                ;;
            list)
                # Return the gaps-list stub if it exists, else empty array
                list_file="$STUB_DIR/_list.json"
                if [[ -f "$list_file" ]]; then
                    cat "$list_file"
                else
                    echo "[]"
                fi
                exit 0
                ;;
            *)
                echo "stub: unknown gap sub: $sub2" >&2; exit 1 ;;
        esac
        ;;
    vote)
        # chump vote <corr_id> <vote> --reason <text>
        corr_id="${2:-}"
        vote_val="${3:-}"
        printf 'STUB_VOTE corr_id=%s vote=%s\n' "$corr_id" "$vote_val" >> "$LOG_FILE"
        echo "vote recorded: $corr_id $vote_val"
        exit 0
        ;;
    *)
        echo "stub: unknown sub: $sub" >&2; exit 1 ;;
esac
STUBEOF
chmod +x "$CHUMP_STUB"

export PATH="$WORK/bin:$PATH"
export CHUMP_TEST_STUB_DIR="$STUB_DIR"
export CHUMP_TEST_LOG="$WORK/chump-calls.log"

# ── gap stubs ─────────────────────────────────────────────────────────────

# Stub 1: VAGUE gap — ac_count=1, ac_has_todos=True
cat > "$STUB_DIR/META-VAGUE.json" << 'EOF'
{
  "id": "META-VAGUE",
  "status": "open",
  "ac_count": 1,
  "ac_has_todos": true,
  "title": "Vague umbrella gap",
  "acceptance_criteria": "[\"TODO: define acceptance criteria\"]",
  "depends_on": ""
}
EOF

# Stub 2: WELL-FORMED gap — status=open, ac_count=4, ac_has_todos=False, no sub-gaps
cat > "$STUB_DIR/META-WELLFORMED.json" << 'EOF'
{
  "id": "META-WELLFORMED",
  "status": "open",
  "ac_count": 4,
  "ac_has_todos": false,
  "title": "Well-formed umbrella gap with clear AC",
  "acceptance_criteria": "[\"AC1\", \"AC2\", \"AC3\", \"AC4\"]",
  "depends_on": ""
}
EOF

# Stub 3: GAP WITH EXISTING SUB-GAPS — ac_count=3, status=open but has children
cat > "$STUB_DIR/META-HASSUBS.json" << 'EOF'
{
  "id": "META-HASSUBS",
  "status": "open",
  "ac_count": 3,
  "ac_has_todos": false,
  "title": "Umbrella with existing sub-gaps",
  "acceptance_criteria": "[\"AC1\", \"AC2\", \"AC3\"]",
  "depends_on": ""
}
EOF

# Gap list for sub-gap detection: one gap depends_on META-HASSUBS
cat > "$STUB_DIR/_list.json" << 'EOF'
[
  {
    "id": "META-HASSUBS-a",
    "status": "open",
    "title": "Sub-gap a of HASSUBS",
    "depends_on": "META-HASSUBS",
    "ac_count": 2,
    "ac_has_todos": false
  }
]
EOF

# ── inject inbox events ───────────────────────────────────────────────────

INBOX_FILE="$INBOX_DIR/$SESSION_ID.jsonl"

TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# Event 1: FEEDBACK kind=proposal for VAGUE gap
printf '{"ts":"%s","event":"FEEDBACK","kind":"proposal","corr_id":"corr-vague-001","session":"other-session-1","subject":"META-VAGUE","rationale":"please review"}\n' \
    "$TS" >> "$INBOX_FILE"

# Event 2: FEEDBACK kind=proposal for WELL-FORMED gap
printf '{"ts":"%s","event":"FEEDBACK","kind":"proposal","corr_id":"corr-wellformed-002","session":"other-session-2","subject":"META-WELLFORMED","rationale":"ready to slice"}\n' \
    "$TS" >> "$INBOX_FILE"

# Event 3: FEEDBACK kind=proposal for gap WITH EXISTING SUB-GAPS
printf '{"ts":"%s","event":"FEEDBACK","kind":"proposal","corr_id":"corr-hassubs-003","session":"other-session-3","subject":"META-HASSUBS","rationale":"already has children"}\n' \
    "$TS" >> "$INBOX_FILE"

# ── run reactor ───────────────────────────────────────────────────────────

echo "=== test-decompose-reactor.sh ==="
echo ""
echo "-- Running Phase 1.5 reactor with CHUMP_FLEET_WIRE_V1=1 --"
echo ""

reactor_output="$(
    CHUMP_FLEET_WIRE_V1=1 \
    CHUMP_LOCK_DIR="$LOCK_DIR" \
    CHUMP_AMBIENT_LOG="$AMBIENT" \
    CHUMP_SESSION_ID="$SESSION_ID" \
    CHUMP_TEST_STUB_DIR="$STUB_DIR" \
    bash "$DECOMPOSE_LOOP" tick 2>&1 || true
)"

echo "$reactor_output"
echo ""

# ── assertions ────────────────────────────────────────────────────────────

echo "=== Assertions ==="

# 1. Feature flag: with CHUMP_FLEET_WIRE_V1=0 (default), reactor is skipped
noflag_output="$(
    CHUMP_FLEET_WIRE_V1=0 \
    CHUMP_LOCK_DIR="$LOCK_DIR" \
    CHUMP_AMBIENT_LOG="$AMBIENT" \
    CHUMP_SESSION_ID="$SESSION_ID" \
    CHUMP_TEST_STUB_DIR="$STUB_DIR" \
    bash "$DECOMPOSE_LOOP" tick 2>&1 || true
)"
assert_contains \
    "feature flag off: reactor Phase 1.5 skipped" \
    "Phase 1.5 skipped" \
    "$noflag_output"

# 2. Vague gap → vote -1
assert_contains \
    "vague gap gets vote=-1 in reactor output" \
    'vote=-1' \
    "$reactor_output"

# 3. Well-formed gap → vote +1
assert_contains \
    "well-formed gap gets vote=+1 in reactor output" \
    'vote=+1' \
    "$reactor_output"

# 4. Gap with existing sub-gaps → vote -1 (existing_sub_gaps detected)
assert_contains \
    "gap with sub-gaps gets vote=-1 (existing_sub_gaps)" \
    'existing_sub_gaps' \
    "$reactor_output"

# 5. Three kind=decompose_reactor_voted events emitted to ambient
voted_count="$(grep -c '"kind":"decompose_reactor_voted"' "$AMBIENT" 2>/dev/null || echo 0)"
if [[ "$voted_count" -ge 3 ]]; then
    _pass "ambient has >= 3 decompose_reactor_voted events (got $voted_count)"
else
    _fail "ambient should have >= 3 decompose_reactor_voted events, got $voted_count"
fi

# 6. Cooldown: re-inject the same corr_ids into inbox, verify they are skipped
# because cooldown files now exist.
echo ""
echo "-- Re-injecting events to verify 1h cooldown dedupe --"
INBOX_FILE_COOLDOWN="$INBOX_DIR/cooldown-test-session.jsonl"
printf '{"ts":"%s","event":"FEEDBACK","kind":"proposal","corr_id":"corr-vague-001","session":"other-session-1","subject":"META-VAGUE","rationale":"retry"}\n' \
    "$TS" >> "$INBOX_FILE_COOLDOWN"
printf '{"ts":"%s","event":"FEEDBACK","kind":"proposal","corr_id":"corr-wellformed-002","session":"other-session-2","subject":"META-WELLFORMED","rationale":"retry"}\n' \
    "$TS" >> "$INBOX_FILE_COOLDOWN"
printf '{"ts":"%s","event":"FEEDBACK","kind":"proposal","corr_id":"corr-hassubs-003","session":"other-session-3","subject":"META-HASSUBS","rationale":"retry"}\n' \
    "$TS" >> "$INBOX_FILE_COOLDOWN"
reactor_output2="$(
    CHUMP_FLEET_WIRE_V1=1 \
    CHUMP_LOCK_DIR="$LOCK_DIR" \
    CHUMP_AMBIENT_LOG="$AMBIENT" \
    CHUMP_SESSION_ID="cooldown-test-session" \
    CHUMP_TEST_STUB_DIR="$STUB_DIR" \
    bash "$DECOMPOSE_LOOP" tick 2>&1 || true
)"
assert_contains \
    "second run: at least 1 corr_id in cooldown" \
    "in cooldown" \
    "$reactor_output2"

# 7. Anti-loop: kind=vote events in inbox are never processed as proposals.
# The reactor collects only kind=proposal from inbox; kind=vote is filtered at
# collection time. A tick with only a kind=vote inbox event produces no votes.
INBOX_FILE2="$INBOX_DIR/vote-test-session.jsonl"
printf '{"ts":"%s","event":"FEEDBACK","kind":"vote","corr_id":"corr-vote-skip","session":"other-session","subject":"META-WELLFORMED"}\n' \
    "$TS" >> "$INBOX_FILE2"
# Also put a kind=proposal in the same inbox — and verify the vote event is NOT voted on
printf '{"ts":"%s","event":"FEEDBACK","kind":"proposal","corr_id":"corr-vote-proposal","session":"other-session","subject":"META-WELLFORMED"}\n' \
    "$TS" >> "$INBOX_FILE2"
vote_output="$(
    CHUMP_FLEET_WIRE_V1=1 \
    CHUMP_LOCK_DIR="$LOCK_DIR" \
    CHUMP_AMBIENT_LOG="$AMBIENT" \
    CHUMP_SESSION_ID="vote-test-session" \
    CHUMP_TEST_STUB_DIR="$STUB_DIR" \
    bash "$DECOMPOSE_LOOP" tick 2>&1 || true
)"
# Only 1 vote should have been emitted (for the proposal, not the vote event).
# The vote event's corr_id should NOT appear as a voted corr_id.
assert_not_contains \
    "anti-loop: kind=vote corr_id not voted on" \
    "corr-vote-skip" \
    "$vote_output"
assert_contains \
    "anti-loop: the proposal event IS processed (reactor is active)" \
    "corr-vote-proposal" \
    "$vote_output"

# 8. Anti-loop: own-session events are skipped
INBOX_FILE3="$INBOX_DIR/own-session-test.jsonl"
printf '{"ts":"%s","event":"FEEDBACK","kind":"proposal","corr_id":"corr-own-skip","session":"own-session-test","subject":"META-WELLFORMED"}\n' \
    "$TS" >> "$INBOX_FILE3"
own_output="$(
    CHUMP_FLEET_WIRE_V1=1 \
    CHUMP_LOCK_DIR="$LOCK_DIR" \
    CHUMP_AMBIENT_LOG="$AMBIENT" \
    CHUMP_SESSION_ID="own-session-test" \
    CHUMP_TEST_STUB_DIR="$STUB_DIR" \
    bash "$DECOMPOSE_LOOP" tick 2>&1 || true
)"
assert_contains \
    "anti-loop: own-session events are skipped" \
    "skipping own-session" \
    "$own_output"

# ── summary ───────────────────────────────────────────────────────────────

echo ""
echo "=== Results: $pass passed, $fail failed ==="

if [[ "$fail" -gt 0 ]]; then
    exit 1
fi
exit 0
