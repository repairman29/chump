#!/usr/bin/env bash
# test-a2a-rpc-bash-v0.sh — INFRA-1828 smoke test for the 5 bash RPC wrappers.
#
# Verifies:
#   1. _rpc_lib loadable, exports _rpc_send/_rpc_await/_rpc_call.
#   2. _rpc_send writes a recipient inbox line with the expected JSON envelope.
#   3. _rpc_await times out cleanly when no reply lands (rc=124 + ambient emit).
#   4. _rpc_await completes when a matching corr_id reply is in the inbox.
#   5. Each of the 5 wrappers handles wrong-arg-count by exiting 2 + usage.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
RPC_DIR="$REPO_ROOT/scripts/coord/rpc"
LIB="$RPC_DIR/_rpc_lib.sh"

[[ -r "$LIB" ]] || { echo "FAIL: $LIB missing"; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Isolate ambient + inbox writes under TMP.
export CHUMP_LOCK_DIR="$TMP/locks"
export CHUMP_AMBIENT_LOG="$TMP/locks/ambient.jsonl"
mkdir -p "$TMP/locks/inbox"
touch "$CHUMP_AMBIENT_LOG"
export CHUMP_SESSION_ID="test-rpc-caller"
export CHUMP_RPC_TIMEOUT_S=2   # short timeouts so the test is fast.

# ── Test 1: lib loadable + exports symbols ───────────────────────────────────
echo "Test 1: lib loads + exports symbols"
out=$(bash -c "source '$LIB'; declare -F _rpc_send _rpc_await _rpc_call" 2>&1)
if [[ "$out" == *"_rpc_send"* && "$out" == *"_rpc_await"* && "$out" == *"_rpc_call"* ]]; then
    echo "  PASS"
else
    echo "  FAIL: missing symbols. got: $out"
    exit 1
fi

# ── Test 2: _rpc_send delivers a payload to target's inbox ───────────────────
echo "Test 2: _rpc_send → recipient inbox"
TARGET="test-rpc-recipient"
TARGET_INBOX="$CHUMP_LOCK_DIR/inbox/${TARGET}.jsonl"
# broadcast.sh resolves its LOCK_DIR from git rev-parse, not from
# CHUMP_LOCK_DIR. For the smoke we stub broadcast.sh on PATH to honor our
# tmp inbox directly — preserves the on-wire shape without touching the
# real .chump-locks/inbox.
mkdir -p "$TMP/bin"
cat > "$TMP/bin/broadcast.sh" <<EOF
#!/usr/bin/env bash
# stub: writes a one-line JSON to the recipient's inbox under TMP.
INBOX_DIR="$CHUMP_LOCK_DIR/inbox"
mkdir -p "\$INBOX_DIR"
recipient=""
event=""
reason=""
while [[ \$# -gt 0 ]]; do
    case "\$1" in
        --to) recipient="\$2"; shift 2 ;;
        --reason) reason="\$2"; shift 2 ;;
        WARN|ALERT|STUCK|INTENT|HANDOFF|DONE|FEEDBACK) event="\$1"; shift ;;
        *) shift ;;
    esac
done
[[ -z "\$recipient" ]] && exit 0
printf '{"event":"%s","reason":"%s","to":"%s","ts":"%s"}\n' \\
    "\$event" "\$reason" "\$recipient" "\$(date -u +%Y-%m-%dT%H:%M:%SZ)" \\
    >> "\$INBOX_DIR/\$recipient.jsonl"
EOF
chmod +x "$TMP/bin/broadcast.sh"
# Override the broadcast.sh path the lib resolves by symlinking it into our
# fake scripts/coord/ path. Since the lib uses an absolute path
# "$REPO_ROOT/scripts/coord/broadcast.sh", we instead override $REPO_ROOT
# inside the source via env. Easier: replace the real-path call with our
# stub via PATH hijack — but the lib uses absolute. So we mask by replacing
# bash builtins. Simplest: use sed-on-source.
LIB_STUBBED="$TMP/_rpc_lib_stubbed.sh"
sed "s|\$REPO_ROOT/scripts/coord/broadcast.sh|$TMP/bin/broadcast.sh|g" "$LIB" > "$LIB_STUBBED"
req_id=$(bash -c "source '$LIB_STUBBED'; _rpc_send '$TARGET' 'ask-eta' '{\"gap_id\":\"INFRA-X\"}'" 2>&1 | tail -1)
if [[ -z "$req_id" || "$req_id" != rpc-* ]]; then
    echo "  FAIL: bad req_id: $req_id"
    exit 1
fi
if [[ -r "$TARGET_INBOX" ]] && grep -q "$req_id" "$TARGET_INBOX" && grep -q '"rpc":"ask-eta"' "$TARGET_INBOX"; then
    echo "  PASS (req_id=$req_id landed in $TARGET_INBOX)"
else
    echo "  FAIL: payload missing in $TARGET_INBOX"
    [[ -r "$TARGET_INBOX" ]] && cat "$TARGET_INBOX"
    exit 1
fi

# ── Test 3: _rpc_await times out → rc=124 + ambient emit ────────────────────
echo "Test 3: _rpc_await timeout → rc=124 + ambient emit"
> "$CHUMP_AMBIENT_LOG"
# Fake a request_id we never reply to.
ghost_id="rpc-ghost-deadbeef"
out=$(bash -c "source '$LIB'; _rpc_await '$ghost_id' 1" 2>&1) && rc=0 || rc=$?
if [[ "$rc" -eq 124 ]] && grep -q '"kind":"a2a_rpc_timeout"' "$CHUMP_AMBIENT_LOG" && grep -q "$ghost_id" "$CHUMP_AMBIENT_LOG"; then
    echo "  PASS (rc=$rc + ambient emit)"
else
    echo "  FAIL: rc=$rc; ambient:"
    cat "$CHUMP_AMBIENT_LOG"
    exit 1
fi

# ── Test 4: _rpc_await completes when reply lands ────────────────────────────
echo "Test 4: _rpc_await catches matching reply"
> "$CHUMP_AMBIENT_LOG"
# Build a fake reply in our own inbox.
SELF_INBOX="$CHUMP_LOCK_DIR/inbox/test-rpc-caller.jsonl"
mkdir -p "$(dirname "$SELF_INBOX")"
reply_id="rpc-test-cafef00d"
# Write a reply via python (avoids bash quoting issues with nested JSON).
python3 -c "
import json
reply = {
    'event': 'WARN',
    'corr_id': '$reply_id',
    'reason': json.dumps({'corr_id': '$reply_id', 'eta_seconds_remaining': 42},
                          separators=(',', ':')),
    'to': 'test-rpc-caller',
    'ts': '2026-05-23T00:00:00Z',
}
print(json.dumps(reply, separators=(',', ':')))
" >> "$SELF_INBOX"

out=$(bash -c "source '$LIB'; _rpc_await '$reply_id' 2" 2>&1) && rc=0 || rc=$?
if [[ "$rc" -eq 0 && "$out" == *"$reply_id"* ]]; then
    echo "  PASS (got reply for $reply_id)"
else
    echo "  FAIL: rc=$rc out=$out"
    exit 1
fi

# ── Test 5: each wrapper exits 2 + usage on wrong arg count ──────────────────
echo "Test 5: wrappers reject wrong-arg-count"
for w in ask-eta ask-overlap ask-handoff ask-progress ask-capability; do
    out=$("$RPC_DIR/$w.sh" 2>&1) && rc=0 || rc=$?
    if [[ "$rc" -eq 2 && "$out" == *"Usage:"* ]]; then
        :  # ok
    else
        echo "  FAIL: $w.sh did not exit 2+Usage. rc=$rc out=$out"
        exit 1
    fi
done
echo "  PASS (all 5 wrappers)"

echo
echo "All 5 a2a-rpc-bash-v0 smoke tests passed."
