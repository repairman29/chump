#!/usr/bin/env bash
# test-server-survives-slow-endpoint.sh — INFRA-1485 / INFRA-1496
#
# Source-level assertions that handlers shelling out to external
# scripts (dep-clean, broadcast.sh, ...) use tokio::process::Command
# wrapped in tokio::time::timeout rather than a blocking
# std::process::Command::output() call — a single slow child process
# must not be able to starve the tokio worker pool and take
# /api/health down with it.
#
# INFRA-1496 case: POST /api/broadcast shells out to
# scripts/coord/broadcast.sh. This asserts that call path specifically
# converted from std::process::Command to tokio::process::Command with
# a bounded timeout, extending the INFRA-1485 audit coverage.
#
# For a live-server repro of the "3x concurrent slow broadcast.sh calls
# must not regress /api/health p95" behavior, see the "Manual repro"
# section in docs/gaps/INFRA-1496.yaml / PR description — this script
# is the static CI gate; the manual repro is the one-time verification.
#
# Run: bash scripts/ci/test-server-survives-slow-endpoint.sh
# Exit 0 = pass.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WEB_SERVER="$REPO_ROOT/src/web_server.rs"

PASS=0; FAIL=0
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

echo "=== INFRA-1496 handle_broadcast async timeout assertions ==="
echo

# Isolate the handle_broadcast function body so assertions are scoped to
# the right handler, not some other Command call in the file.
BROADCAST_BODY="$(awk '/^async fn handle_broadcast\(/,/^}/' "$WEB_SERVER")"

# AC1/AC2: tokio::process::Command replaces std::process::Command inside
# handle_broadcast, and the call is async (.output().await via the
# tokio::time::timeout wrapper below).
if echo "$BROADCAST_BODY" | grep -q "tokio::process::Command::new(\"bash\")"; then
    ok "handle_broadcast uses tokio::process::Command (async, non-blocking)"
else
    fail "handle_broadcast does NOT use tokio::process::Command — still blocking?"
fi

if echo "$BROADCAST_BODY" | grep -q "std::process::Command"; then
    fail "handle_broadcast still references std::process::Command — blocking path not fully removed"
else
    ok "handle_broadcast has no std::process::Command reference"
fi

# AC3: bounded timeout wraps the broadcast.sh invocation so a hung
# script can't wedge the handler (and therefore the worker thread)
# forever.
if echo "$BROADCAST_BODY" | grep -q "tokio::time::timeout"; then
    ok "tokio::time::timeout wraps the broadcast.sh invocation"
else
    fail "tokio::time::timeout NOT found — broadcast.sh call has no bound"
fi

if echo "$BROADCAST_BODY" | grep -q "StatusCode::GATEWAY_TIMEOUT"; then
    ok "timeout path returns StatusCode::GATEWAY_TIMEOUT (observable failure mode)"
else
    fail "no GATEWAY_TIMEOUT response on timeout — caller can't distinguish hang from spawn error"
fi

# AC5 (no synchronous Command::output() left in this code path): the
# handler must call .output() only through the tokio future, never a
# bare synchronous .output() call.
if echo "$BROADCAST_BODY" | grep -qE '\.output\(\)\s*\.map_err'; then
    fail "handle_broadcast still has a synchronous .output().map_err(...) call"
else
    ok "no synchronous .output() call remains in handle_broadcast"
fi

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
