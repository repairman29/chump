#!/usr/bin/env bash
# scripts/ci/test-daemon-silent-noop.sh — INFRA-2009 (THE FLOOR Phase 2)
#
# Validates scripts/coord/lib/silent-noop-guard.sh via stub daemons.
#
# Tests:
#   1. Guard fires: daemon exits rc=0, had input, never calls _sng_mark_done
#      → kind=daemon_silent_noop emitted to ambient
#   2. Guard quiet: daemon exits rc=0, had input, calls _sng_mark_done
#      → no daemon_silent_noop emitted
#   3. Guard quiet: daemon exits rc=0, no input (_SNG_HAD_INPUT=0)
#      → no daemon_silent_noop emitted (nothing to process = clean no-op)
#   4. Guard quiet: daemon exits rc=1 (loud failure path)
#      → no daemon_silent_noop emitted (loud failures don't need the alarm)
#   5. Source tag appears in event: daemon_silent_noop carries the expected
#      source field matching the tag passed to _sng_install_guard

set -uo pipefail

PASS=0
FAIL=0
FAILS=()

ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); FAILS+=("$1"); }

echo "=== INFRA-2009 daemon-silent-noop-guard tests ==="
echo

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
GUARD="$REPO_ROOT/scripts/coord/lib/silent-noop-guard.sh"

if [[ ! -f "$GUARD" ]]; then
    echo "FATAL: guard lib not found: $GUARD"
    exit 2
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

AMBIENT="$TMP/ambient.jsonl"

# ── Helpers ──────────────────────────────────────────────────────────────────

# Run a stub daemon in a subshell. The stub sources the guard, optionally
# sets _SNG_HAD_INPUT=1, optionally calls _sng_mark_done, and exits with
# the given rc.
#
# Usage: run_stub <source_tag> <had_input:0|1> <mark_done:0|1> <exit_rc>
run_stub() {
    local tag="$1" had_input="$2" mark_done="$3" exit_rc="$4"
    bash -c "
        source '$GUARD'
        _sng_install_guard '$tag' '$AMBIENT'
        _SNG_HAD_INPUT=$had_input
        if [[ '$mark_done' == '1' ]]; then
            _sng_mark_done
        fi
        exit $exit_rc
    " 2>/dev/null
}

count_event() {
    local kind="$1"
    # grep -c exits 1 on zero matches; `|| true` ensures always-zero exit so
    # callers using set -e don't abort and n= captures the numeric count.
    { grep -c "\"kind\":\"$kind\"" "$AMBIENT" 2>/dev/null || true; }
}

# ── Test 1: alarm fires when daemon has input but skips main body ─────────────
echo "--- Test 1: had_input=1, mark_done=0, rc=0 → daemon_silent_noop fires ---"
> "$AMBIENT"
run_stub "test_daemon_alpha" 1 0 0 || true
n="$(count_event daemon_silent_noop)"
if [[ "$n" -ge 1 ]]; then
    ok "daemon_silent_noop emitted (count=$n)"
else
    fail "expected daemon_silent_noop, got 0 events in ambient"
fi

# ── Test 2: no alarm when daemon marks work done ──────────────────────────────
echo "--- Test 2: had_input=1, mark_done=1, rc=0 → no alarm ---"
> "$AMBIENT"
run_stub "test_daemon_beta" 1 1 0 || true
n="$(count_event daemon_silent_noop)"
if [[ "$n" -eq 0 ]]; then
    ok "no daemon_silent_noop (mark_done suppresses alarm)"
else
    fail "unexpected daemon_silent_noop emitted (count=$n)"
fi

# ── Test 3: no alarm when daemon has no input ─────────────────────────────────
echo "--- Test 3: had_input=0, mark_done=0, rc=0 → no alarm (nothing to do) ---"
> "$AMBIENT"
run_stub "test_daemon_gamma" 0 0 0 || true
n="$(count_event daemon_silent_noop)"
if [[ "$n" -eq 0 ]]; then
    ok "no daemon_silent_noop when _SNG_HAD_INPUT=0"
else
    fail "unexpected daemon_silent_noop emitted (count=$n)"
fi

# ── Test 4: no alarm on non-zero exit (loud failure path) ────────────────────
echo "--- Test 4: had_input=1, mark_done=0, rc=1 → no alarm (loud failure) ---"
> "$AMBIENT"
run_stub "test_daemon_delta" 1 0 1 || true
n="$(count_event daemon_silent_noop)"
if [[ "$n" -eq 0 ]]; then
    ok "no daemon_silent_noop on rc=1 (loud failures exempt)"
else
    fail "unexpected daemon_silent_noop on non-zero exit (count=$n)"
fi

# ── Test 5: source tag propagated into event ──────────────────────────────────
echo "--- Test 5: source tag appears in emitted event ---"
> "$AMBIENT"
run_stub "my_floor_daemon" 1 0 0 || true
if grep -q '"source":"my_floor_daemon"' "$AMBIENT" 2>/dev/null; then
    ok "source tag 'my_floor_daemon' present in daemon_silent_noop event"
else
    fail "source tag missing from daemon_silent_noop event; ambient: $(cat "$AMBIENT" 2>/dev/null)"
fi

# ── Summary ───────────────────────────────────────────────────────────────────
echo
echo "Results: $PASS passed, $FAIL failed"
if [[ "$FAIL" -gt 0 ]]; then
    echo "FAILED tests:"
    for f in "${FAILS[@]}"; do echo "  - $f"; done
    exit 1
fi
echo "All tests passed."
exit 0
