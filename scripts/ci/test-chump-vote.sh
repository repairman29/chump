#!/usr/bin/env bash
# META-159 AC5: test-chump-vote.sh
# Run `chump vote META-999 +1 --reason "ship it"` and assert the ambient.jsonl
# line contains:  "event":"FEEDBACK"  "kind":"vote"  "vote":1
#                 "corr_id":"META-999"  "rationale":"ship it"
set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
CHUMP_BIN="${CHUMP_BIN:-$REPO_ROOT/target/debug/chump}"

if [[ ! -x "$CHUMP_BIN" ]]; then
    echo "[test-chump-vote] building chump binary..."
    cargo build --manifest-path "$REPO_ROOT/Cargo.toml" --bin chump --quiet
fi

# Isolated ambient log for this test.
TMPDIR_TEST="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_TEST"' EXIT

export CHUMP_AMBIENT_LOG="$TMPDIR_TEST/ambient.jsonl"
export CHUMP_REPO_ROOT="$REPO_ROOT"
export CHUMP_FLEET_RECV_SIDE_V0=1
# Prevent broadcast.sh from touching the real ambient log.
export CHUMP_SESSION_ID="test-vote-$$"

# Override broadcast.sh to emit directly to our temp ambient log
# without needing NATS or the real lock dir.
FAKE_BROADCAST="$TMPDIR_TEST/broadcast.sh"
cat > "$FAKE_BROADCAST" << 'BROADCAST_EOF'
#!/usr/bin/env bash
# Fake broadcast.sh: emit a FEEDBACK preference event to CHUMP_AMBIENT_LOG.
TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
FB_KIND="${2:-preference}"
FB_SUBJECT="${3:-}"
FB_RATIONALE="${4:-}"
FB_VOTE="${5:-0}"
CORR_ID="$FB_SUBJECT"
LINE="{\"ts\":\"$TS\",\"event\":\"FEEDBACK\",\"kind\":\"$FB_KIND\",\"corr_id\":\"$CORR_ID\",\"vote\":$FB_VOTE,\"rationale\":\"$FB_RATIONALE\",\"session\":\"${CHUMP_SESSION_ID:-test}\"}"
echo "$LINE" >> "${CHUMP_AMBIENT_LOG:-.chump-locks/ambient.jsonl}"
echo "[broadcast] FEEDBACK kind=$FB_KIND subject=$FB_SUBJECT"
BROADCAST_EOF
chmod +x "$FAKE_BROADCAST"

# Patch PATH so chump uses our fake broadcast.sh via CHUMP_BROADCAST_PATH override
# OR via a scripts/coord/ shim directory.
SHIM_DIR="$TMPDIR_TEST/scripts/coord"
mkdir -p "$SHIM_DIR"
cp "$FAKE_BROADCAST" "$SHIM_DIR/broadcast.sh"

# Use CHUMP_REPO_ROOT pointing to a temp dir where scripts/coord/broadcast.sh
# is our fake. We achieve this by symlinking everything except scripts/coord.
FAKE_ROOT="$TMPDIR_TEST/fakeroot"
mkdir -p "$FAKE_ROOT/scripts/coord"
cp "$FAKE_BROADCAST" "$FAKE_ROOT/scripts/coord/broadcast.sh"
# Symlink the rest of the repo so chump can still find its resources.
# (vote.rs shells out using repo_root()/scripts/coord/broadcast.sh)
# We override CHUMP_REPO_ROOT to point to the fake root for the broadcast call.
# But chump vote uses CHUMP_REPO_ROOT to find broadcast.sh.
export CHUMP_REPO_ROOT="$FAKE_ROOT"

echo "[test-chump-vote] running: chump vote META-999 +1 --reason \"ship it\""
"$CHUMP_BIN" vote META-999 +1 --reason "ship it"

echo "[test-chump-vote] checking ambient.jsonl..."
if [[ ! -f "$CHUMP_AMBIENT_LOG" ]]; then
    echo "FAIL: ambient.jsonl not created at $CHUMP_AMBIENT_LOG"
    exit 1
fi

# Find the kind=vote line (the direct emit from vote.rs, not the broadcast preference line).
VOTE_LINE="$(grep '"kind":"vote"' "$CHUMP_AMBIENT_LOG" || true)"

if [[ -z "$VOTE_LINE" ]]; then
    echo "FAIL: no line with \"kind\":\"vote\" in ambient.jsonl"
    echo "--- ambient.jsonl contents ---"
    cat "$CHUMP_AMBIENT_LOG"
    exit 1
fi

echo "[test-chump-vote] found vote line: $VOTE_LINE"

# Assert required fields.
assert_field() {
    local field="$1" expected="$2" line="$3"
    if ! echo "$line" | grep -qF "\"$field\":$expected"; then
        echo "FAIL: expected \"$field\":$expected in: $line"
        exit 1
    fi
}

assert_field_str() {
    local field="$1" expected="$2" line="$3"
    if ! echo "$line" | grep -qF "\"$field\":\"$expected\""; then
        echo "FAIL: expected \"$field\":\"$expected\" in: $line"
        exit 1
    fi
}

assert_field_str "event"    "FEEDBACK"  "$VOTE_LINE"
assert_field_str "kind"     "vote"      "$VOTE_LINE"
assert_field     "vote"     "1"         "$VOTE_LINE"
assert_field_str "corr_id"  "META-999"  "$VOTE_LINE"
assert_field_str "rationale" "ship it"  "$VOTE_LINE"

echo "[test-chump-vote] PASS — all fields present in kind=vote event"
