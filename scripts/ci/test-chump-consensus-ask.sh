#!/usr/bin/env bash
# INFRA-2156 (META-125/C5) AC4: test-chump-consensus-ask.sh
#
# Three scenarios against `chump consensus ask`:
#   1. non-blocking publish: consensus_ask_published lands with a consensus_id.
#   2. --block resolves: seed a consensus_result first, assert exit 0 +
#      consensus_ask_resolved with the verdict.
#   3. --block times out: no consensus_result ever lands, assert exit 3 +
#      consensus_ask_timeout with failure_class=transient.
set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
CHUMP_BIN="${CHUMP_BIN:-$REPO_ROOT/target/debug/chump}"

if [[ ! -x "$CHUMP_BIN" ]]; then
    echo "[test-chump-consensus-ask] building chump binary..."
    cargo build --manifest-path "$REPO_ROOT/Cargo.toml" --bin chump --quiet
fi

TMPDIR_TEST="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_TEST"' EXIT

export CHUMP_FLEET_RECV_SIDE_V0=1
export CHUMP_SESSION_ID="test-consensus-ask-$$"
export CHUMP_CONSENSUS_ASK_POLL_SECS=1

# Fake broadcast.sh: just append a FEEDBACK proposal line to CHUMP_AMBIENT_LOG,
# mirroring test-chump-vote.sh's approach (no NATS/lock-dir dependency).
FAKE_ROOT="$TMPDIR_TEST/fakeroot"
mkdir -p "$FAKE_ROOT/scripts/coord"
cat > "$FAKE_ROOT/scripts/coord/broadcast.sh" << 'BROADCAST_EOF'
#!/usr/bin/env bash
TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
FB_KIND="${2:-proposal}"
FB_SUBJECT="${3:-}"
FB_RATIONALE="${4:-}"
LINE="{\"ts\":\"$TS\",\"event\":\"FEEDBACK\",\"kind\":\"$FB_KIND\",\"corr_id\":\"$FB_SUBJECT\",\"subject\":\"$FB_SUBJECT\",\"rationale\":\"$FB_RATIONALE\",\"session\":\"${CHUMP_SESSION_ID:-test}\"}"
echo "$LINE" >> "${CHUMP_AMBIENT_LOG:-.chump-locks/ambient.jsonl}"
echo "[broadcast] FEEDBACK kind=$FB_KIND subject=$FB_SUBJECT"
BROADCAST_EOF
chmod +x "$FAKE_ROOT/scripts/coord/broadcast.sh"
export CHUMP_REPO_ROOT="$FAKE_ROOT"

assert_contains() {
    local needle="$1" haystack="$2" what="$3"
    if [[ "$haystack" != *"$needle"* ]]; then
        echo "FAIL: expected $what to contain: $needle"
        echo "--- got ---"
        echo "$haystack"
        exit 1
    fi
}

# ── Scenario 1: non-blocking publish ─────────────────────────────────────────
echo "[test-chump-consensus-ask] scenario 1: non-blocking publish"
AMBIENT_1="$TMPDIR_TEST/ambient-1.jsonl"
export CHUMP_AMBIENT_LOG="$AMBIENT_1"

OUT_1="$("$CHUMP_BIN" consensus ask "should we scale to 4 workers?" --id "consensus-scale-1" --reason "waste rate is low")"
echo "$OUT_1"
assert_contains "consensus-scale-1" "$OUT_1" "scenario 1 stdout"

PUBLISHED_LINE="$(grep '"kind":"consensus_ask_published"' "$AMBIENT_1" || true)"
[[ -n "$PUBLISHED_LINE" ]] || { echo "FAIL: no consensus_ask_published line in $AMBIENT_1"; cat "$AMBIENT_1"; exit 1; }
assert_contains '"corr_id":"consensus-scale-1"' "$PUBLISHED_LINE" "consensus_ask_published line"
assert_contains '"event":"FEEDBACK"' "$PUBLISHED_LINE" "consensus_ask_published line"

PROPOSAL_LINE="$(grep '"kind":"proposal"' "$AMBIENT_1" || true)"
[[ -n "$PROPOSAL_LINE" ]] || { echo "FAIL: no FEEDBACK kind=proposal line published via broadcast.sh"; exit 1; }

# ── Scenario 2: --block resolves before timeout ──────────────────────────────
echo "[test-chump-consensus-ask] scenario 2: --block resolves"
AMBIENT_2="$TMPDIR_TEST/ambient-2.jsonl"
export CHUMP_AMBIENT_LOG="$AMBIENT_2"

# Seed the consensus_result BEFORE calling ask so the first poll finds it.
printf '{"ts":"2026-08-14T00:00:00Z","event":"FEEDBACK","kind":"consensus_result","corr_id":"consensus-scale-2","verdict":"PASSED"}\n' >> "$AMBIENT_2"

set +e
OUT_2="$("$CHUMP_BIN" consensus ask "should we scale to 4 workers?" --id "consensus-scale-2" --reason "waste rate is low" --block --timeout 10)"
RC_2=$?
set -e
echo "$OUT_2"
[[ "$RC_2" -eq 0 ]] || { echo "FAIL: expected exit 0 for resolved --block, got $RC_2"; exit 1; }
assert_contains "PASSED" "$OUT_2" "scenario 2 stdout"

RESOLVED_LINE="$(grep '"kind":"consensus_ask_resolved"' "$AMBIENT_2" || true)"
[[ -n "$RESOLVED_LINE" ]] || { echo "FAIL: no consensus_ask_resolved line in $AMBIENT_2"; cat "$AMBIENT_2"; exit 1; }
assert_contains '"verdict":"PASSED"' "$RESOLVED_LINE" "consensus_ask_resolved line"
assert_contains '"poll_count"' "$RESOLVED_LINE" "consensus_ask_resolved line (cost tracking)"
assert_contains '"elapsed_secs"' "$RESOLVED_LINE" "consensus_ask_resolved line (cost tracking)"

# ── Scenario 3: --block times out (no consensus_result ever lands) ──────────
echo "[test-chump-consensus-ask] scenario 3: --block timeout"
AMBIENT_3="$TMPDIR_TEST/ambient-3.jsonl"
export CHUMP_AMBIENT_LOG="$AMBIENT_3"

set +e
OUT_3="$("$CHUMP_BIN" consensus ask "should we scale to 4 workers?" --id "consensus-scale-3" --reason "waste rate is low" --block --timeout 2 2>&1)"
RC_3=$?
set -e
echo "$OUT_3"
[[ "$RC_3" -eq 3 ]] || { echo "FAIL: expected exit 3 for --block timeout, got $RC_3"; exit 1; }

TIMEOUT_LINE="$(grep '"kind":"consensus_ask_timeout"' "$AMBIENT_3" || true)"
[[ -n "$TIMEOUT_LINE" ]] || { echo "FAIL: no consensus_ask_timeout line in $AMBIENT_3"; cat "$AMBIENT_3"; exit 1; }
assert_contains '"failure_class":"transient"' "$TIMEOUT_LINE" "consensus_ask_timeout line (failure-class taxonomy)"
assert_contains '"poll_count"' "$TIMEOUT_LINE" "consensus_ask_timeout line (cost tracking)"

echo "[test-chump-consensus-ask] PASS — publish, --block resolve, and --block timeout all verified"
