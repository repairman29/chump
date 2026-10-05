#!/usr/bin/env bash
# test-a2a-rpc-observability.sh — INFRA-2358 smoke test
#
# A2A typed RPC v1 observability: verifies the 4 terminal ambient event
# kinds (a2a_rpc_finished / a2a_rpc_timeout / a2a_rpc_send_failed /
# a2a_rpc_handler_crash) are registered, that latency_ms rides along on
# success, that failure_class (transient|permanent) is wired on every
# failure path, and that both the Rust (crates/chump-coord/src/rpc.rs) and
# bash (scripts/coord/rpc/_rpc_lib.sh) transports actually emit them.
#
# Acceptance criteria verified (per docs/gaps/INFRA-2358.yaml):
#   (1) All 4 event kinds registered in EVENT_REGISTRY.yaml, with a
#       scanner-anchor or matching literal in both rpc.rs and _rpc_lib.sh.
#   (2) a2a_rpc_finished carries latency_ms — checked in both paths.
#   (3) failure_class field present on every failure-path emission in both
#       paths (transient for timeout/send_failed, permanent for
#       handler_crash).
#   (4) `cargo test -p chump-coord --lib rpc::` passes.
#
# Exits non-zero on any check failure.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$REPO_ROOT"

REGISTRY="docs/observability/EVENT_REGISTRY.yaml"
RUST_SRC="crates/chump-coord/src/rpc.rs"
BASH_SRC="scripts/coord/rpc/_rpc_lib.sh"

PASS=0
FAIL=0

ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

echo "=== INFRA-2358 a2a-rpc-observability smoke test ==="
echo

# ── 1. Registry entries exist for all 4 terminal kinds ───────────────────────
echo "Test 1: EVENT_REGISTRY.yaml has all 4 terminal RPC event kinds"
for kind in a2a_rpc_finished a2a_rpc_timeout a2a_rpc_send_failed a2a_rpc_handler_crash; do
    if grep -qE "^\s*-\s+kind:\s*${kind}\b" "$REGISTRY"; then
        ok "registered: $kind"
    else
        fail "not registered in $REGISTRY: $kind"
    fi
done

# ── 2. Both Rust and bash paths emit each kind ────────────────────────────────
echo
echo "Test 2: both transports (rpc.rs + _rpc_lib.sh) emit each kind"
for kind in a2a_rpc_finished a2a_rpc_timeout a2a_rpc_send_failed a2a_rpc_handler_crash; do
    if grep -q "\"kind\":\"${kind}\"" "$RUST_SRC"; then
        ok "rpc.rs emits: $kind"
    else
        fail "rpc.rs missing emit literal for: $kind"
    fi
    if grep -q "\"kind\":\"${kind}\"" "$BASH_SRC"; then
        ok "_rpc_lib.sh emits: $kind"
    else
        fail "_rpc_lib.sh missing emit literal for: $kind"
    fi
done

# ── 3. latency_ms rides along on a2a_rpc_finished in both paths ──────────────
echo
echo "Test 3: latency_ms present on a2a_rpc_finished in both paths"
if grep -B2 '"kind":"a2a_rpc_finished"' "$RUST_SRC" | grep -q 'latency_ms' \
    || grep -A1 '"kind":"a2a_rpc_finished"' "$RUST_SRC" | grep -q 'latency_ms'; then
    ok "rpc.rs a2a_rpc_finished carries latency_ms"
else
    fail "rpc.rs a2a_rpc_finished missing latency_ms"
fi
if grep -q '"kind":"a2a_rpc_finished","request_id":"%s","latency_ms"' "$BASH_SRC"; then
    ok "_rpc_lib.sh a2a_rpc_finished carries latency_ms"
else
    fail "_rpc_lib.sh a2a_rpc_finished missing latency_ms"
fi

# ── 4. failure_class wired on every failure path, both languages ─────────────
echo
echo "Test 4: failure_class present on timeout/send_failed/handler_crash"
for kind in a2a_rpc_timeout a2a_rpc_send_failed a2a_rpc_handler_crash; do
    rust_line="$(grep '"kind":"'"${kind}"'"' "$RUST_SRC" || true)"
    if [[ -n "$rust_line" ]] && echo "$rust_line" | grep -q 'failure_class'; then
        ok "rpc.rs $kind carries failure_class"
    else
        fail "rpc.rs $kind missing failure_class (line: $rust_line)"
    fi
    bash_line="$(grep '"kind":"'"${kind}"'"' "$BASH_SRC" || true)"
    if [[ -n "$bash_line" ]] && echo "$bash_line" | grep -q 'failure_class'; then
        ok "_rpc_lib.sh $kind carries failure_class"
    else
        fail "_rpc_lib.sh $kind missing failure_class (line: $bash_line)"
    fi
done

# ── 5. RpcError::failure_class() exists and classifies transient/permanent ──
echo
echo "Test 5: RpcError::failure_class() taxonomy present in rpc.rs"
if grep -q 'fn failure_class' "$RUST_SRC"; then
    ok "failure_class() fn defined"
else
    fail "failure_class() fn not found in $RUST_SRC"
fi
if grep -q '"transient"' "$RUST_SRC" && grep -q '"permanent"' "$RUST_SRC"; then
    ok "both transient and permanent classes present"
else
    fail "missing transient/permanent literal in $RUST_SRC"
fi

# ── 6. Live bash-transport check: success path emits finished+latency_ms ────
echo
echo "Test 6: live bash _rpc_await success path emits a2a_rpc_finished"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/locks/inbox"
(
    export CHUMP_LOCK_DIR="$TMP/locks"
    export CHUMP_AMBIENT_LOG="$TMP/locks/ambient.jsonl"
    touch "$CHUMP_AMBIENT_LOG"
    export CHUMP_SESSION_ID="test-obs-caller"
    reply_id="rpc-obs-finish01"
    python3 -c "
import json
reply_id='$reply_id'
reply = {'event': 'WARN', 'corr_id': reply_id,
         'reason': json.dumps({'corr_id': reply_id, 'ok': True}),
         'to': 'test-obs-caller', 'ts': '2026-08-17T00:00:00Z'}
print(json.dumps(reply))
" >> "$TMP/locks/inbox/test-obs-caller.jsonl"
    bash -c "source '$BASH_SRC'; _rpc_await '$reply_id' 2" >/dev/null
    grep -q '"kind":"a2a_rpc_finished"' "$CHUMP_AMBIENT_LOG" \
        && grep -q '"request_id":"'"$reply_id"'"' "$CHUMP_AMBIENT_LOG" \
        && grep -qE '"latency_ms":[0-9]+' "$CHUMP_AMBIENT_LOG"
) && ok "live emit: a2a_rpc_finished with latency_ms" || fail "live emit missing/malformed a2a_rpc_finished"

# ── 7. Live bash-transport check: handler_crash reply path ──────────────────
echo
echo "Test 7: live bash _rpc_await handler_crash path emits a2a_rpc_handler_crash"
TMP2="$(mktemp -d)"
mkdir -p "$TMP2/locks/inbox"
(
    export CHUMP_LOCK_DIR="$TMP2/locks"
    export CHUMP_AMBIENT_LOG="$TMP2/locks/ambient.jsonl"
    touch "$CHUMP_AMBIENT_LOG"
    export CHUMP_SESSION_ID="test-obs-caller2"
    reply_id="rpc-obs-crash01"
    python3 -c "
import json
reply_id='$reply_id'
reply = {'event': 'WARN', 'corr_id': reply_id,
         'reason': json.dumps({'corr_id': reply_id, 'error': 'handler_crash: boom'}),
         'to': 'test-obs-caller2', 'ts': '2026-08-17T00:00:00Z'}
print(json.dumps(reply))
" >> "$TMP2/locks/inbox/test-obs-caller2.jsonl"
    bash -c "source '$BASH_SRC'; _rpc_await '$reply_id' 2" >/dev/null
    grep -q '"kind":"a2a_rpc_handler_crash"' "$CHUMP_AMBIENT_LOG" \
        && grep -q '"failure_class":"permanent"' "$CHUMP_AMBIENT_LOG"
)
rc=$?
rm -rf "$TMP2"
if [[ "$rc" -eq 0 ]]; then
    ok "live emit: a2a_rpc_handler_crash with failure_class=permanent"
else
    fail "live emit missing/malformed a2a_rpc_handler_crash"
fi

# ── 8. cargo test -p chump-coord --lib rpc:: ─────────────────────────────────
echo
echo "Test 8: cargo test -p chump-coord --lib rpc::"
if command -v cargo >/dev/null 2>&1; then
    export PATH="$HOME/.cargo/bin:$PATH"
    if cargo test -p chump-coord --lib rpc:: 2>&1 | tee "$TMP/cargo-test.log" | tail -20; then
        if grep -q 'test result: ok' "$TMP/cargo-test.log"; then
            ok "cargo test -p chump-coord --lib rpc:: passed"
        else
            fail "cargo test ran but did not report 'test result: ok'"
        fi
    else
        fail "cargo test -p chump-coord --lib rpc:: failed"
    fi
else
    echo "  SKIP: cargo not on PATH"
fi

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
