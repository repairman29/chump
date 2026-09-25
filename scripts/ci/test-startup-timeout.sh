#!/usr/bin/env bash
# test-startup-timeout.sh — INFRA-3784 (INFRA-1809 slice)
#
# Verifies the startup wallclock budget: CHUMP_STARTUP_TIMEOUT_MS=1 must
# make `chump --version` (the fastest possible dispatch path) trip the
# timeout, exit code 4, and emit kind=chump_startup_timeout to
# ambient.jsonl. Also checks the default (no env var) path is unaffected.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
PASS=0
FAIL=0
ok()  { echo "  PASS: $1"; PASS=$((PASS+1)); }
bad() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

echo "=== INFRA-3784: startup wallclock timeout ==="

BIN="${CHUMP_BIN:-}"
if [ -z "$BIN" ]; then
    for candidate in \
        "$REPO_ROOT/target/debug/chump" \
        "$REPO_ROOT/target/release/chump" \
        "$HOME/.cargo/chump-shared-target/debug/chump"; do
        if [ -x "$candidate" ]; then
            BIN="$candidate"
            break
        fi
    done
fi

if [ -z "$BIN" ] || [ ! -x "$BIN" ]; then
    echo "  SKIP: no built chump binary found (set CHUMP_BIN or build one first)"
    exit 0
fi

# crate::ambient_emit::emit() (the Rust struct-init call this feature uses,
# same shape as self_doctor_tick) doesn't honor $CHUMP_AMBIENT_LOG — it
# resolves the repo's real ambient.jsonl via `git rev-parse
# --git-common-dir`, same as every other in-binary emit call site. It also
# writes the EmitArgs.kind value into the legacy `"event"` JSON key
# (dual-write bridge, see EVENT_REGISTRY.yaml header) rather than a literal
# `"kind"` key — so we assert on `"event":"chump_startup_timeout"`.
GIT_COMMON_DIR="$(git -C "$REPO_ROOT" rev-parse --git-common-dir)"
AMBIENT_LOG="$(cd "$(dirname "$GIT_COMMON_DIR")" && pwd)/.chump-locks/ambient.jsonl"
PRE_LINES="$(wc -l <"$AMBIENT_LOG" 2>/dev/null || echo 0)"

# ── 1. env-var read + timeout enforcement (AC1, AC2, AC4, AC5) ──────────────
STDERR_OUT="$(mktemp)"
CHUMP_STARTUP_TIMEOUT_MS=1 "$BIN" --version >/dev/null 2>"$STDERR_OUT"
code=$?

if [ "$code" -eq 4 ]; then
    ok "CHUMP_STARTUP_TIMEOUT_MS=1 chump --version exits 4"
else
    bad "CHUMP_STARTUP_TIMEOUT_MS=1 chump --version exited $code, expected 4"
fi

if grep -q 'chump_startup_timeout' "$STDERR_OUT"; then
    ok "stderr diagnostic dump present"
else
    bad "no [chump_startup_timeout] diagnostic on stderr"
fi

NEW_EVENTS="$(tail -n "+$((PRE_LINES + 1))" "$AMBIENT_LOG" 2>/dev/null)"
if echo "$NEW_EVENTS" | grep -q '"event":"chump_startup_timeout"'; then
    ok "ambient event kind=chump_startup_timeout emitted"
    line="$(echo "$NEW_EVENTS" | grep '"event":"chump_startup_timeout"' | tail -1)"
    for field in '"cmd"' '"args"' '"elapsed_ms"' '"suspected_subsystem"'; do
        if echo "$line" | grep -q "$field"; then
            ok "ambient event has field $field"
        else
            bad "ambient event missing field $field"
        fi
    done
else
    bad "no kind=chump_startup_timeout event in ambient log"
fi

# ── 2. default budget (5000ms) does not trip on a fast command (AC1) ────────
"$BIN" --version >/dev/null 2>/dev/null
code=$?
if [ "$code" -eq 0 ]; then
    ok "default startup budget does not trip chump --version"
else
    bad "default startup budget unexpectedly exited $code"
fi

# ── 3. EVENT_REGISTRY.yaml has a matching entry ──────────────────────────────
if grep -q 'kind: chump_startup_timeout' "$REPO_ROOT/docs/observability/EVENT_REGISTRY.yaml"; then
    ok "EVENT_REGISTRY.yaml documents chump_startup_timeout"
else
    bad "EVENT_REGISTRY.yaml missing chump_startup_timeout entry"
fi

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
