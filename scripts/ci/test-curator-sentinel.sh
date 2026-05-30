#!/usr/bin/env bash
# test-curator-sentinel.sh — META-163: smoke test for curator-sentinel lib.

set -uo pipefail

REPO_ROOT="${REPO_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
LIB="$REPO_ROOT/scripts/coord/lib/curator-sentinel.sh"

if [[ ! -f "$LIB" ]]; then
    echo "FAIL: $LIB not found" >&2
    exit 1
fi

_pass=0
_fail=0
_ok()  { echo "  ✓ $*"; _pass=$((_pass + 1)); }
_bad() { echo "  ✗ FAIL: $*" >&2; _fail=$((_fail + 1)); }

# ── Test 1: bash -n syntax ────────────────────────────────────────────────
echo "Test 1: bash -n syntax check..."
if bash -n "$LIB"; then
    _ok "bash -n passes"
else
    _bad "bash -n failed"
fi

# Set up tmp lock dir
FIX="$(mktemp -d)"
export CHUMP_LOCK_DIR="$FIX"
mkdir -p "$FIX"
touch "$FIX/ambient.jsonl"

# ── Test 2: _create_curator_sentinel writes sentinel + emits event ──────────
echo "Test 2: _create_curator_sentinel basic..."
# Subshell so trap doesn't leak across tests
(
    # shellcheck source=/dev/null
    source "$LIB"
    _create_curator_sentinel "ci-audit"
)
if [[ -f "$FIX/.curator-opus-ci-audit.lock" ]]; then
    _ok "sentinel file created"
else
    _bad "sentinel file missing"
fi
if grep -q '"kind":"curator_sentinel_created"' "$FIX/ambient.jsonl" 2>/dev/null; then
    _ok "curator_sentinel_created event emitted"
else
    _bad "curator_sentinel_created event missing"
fi
if grep -q '"role":"ci-audit"' "$FIX/ambient.jsonl" 2>/dev/null; then
    _ok "role field present in event"
else
    _bad "role field missing in event"
fi

# ── Test 3: invalid role rejected ──────────────────────────────────────────
echo "Test 3: invalid role rejected..."
_rc=0
(
    # shellcheck source=/dev/null
    source "$LIB"
    _create_curator_sentinel "Invalid Role!" 2>/dev/null
) || _rc=$?
if (( _rc == 1 )); then
    _ok "invalid role exits 1"
else
    _bad "invalid role should exit 1, got $_rc"
fi
if [[ ! -f "$FIX/.curator-opus-Invalid Role!.lock" ]]; then
    _ok "invalid role did NOT create file"
else
    _bad "invalid role created file (security risk)"
fi

# ── Test 4: idempotent re-create ──────────────────────────────────────────
echo "Test 4: idempotent re-create..."
SAVED_PID="$(cat "$FIX/.curator-opus-ci-audit.lock" 2>/dev/null)"
(
    # shellcheck source=/dev/null
    source "$LIB"
    _create_curator_sentinel "ci-audit"
)
NEW_PID="$(cat "$FIX/.curator-opus-ci-audit.lock" 2>/dev/null)"
if [[ -n "$NEW_PID" ]]; then
    _ok "sentinel file still present after idempotent re-create"
else
    _bad "sentinel file disappeared on re-create"
fi

# ── Test 5: _remove_curator_sentinel ──────────────────────────────────────
echo "Test 5: _remove_curator_sentinel..."
(
    # shellcheck source=/dev/null
    source "$LIB"
    _remove_curator_sentinel "ci-audit"
)
if [[ ! -f "$FIX/.curator-opus-ci-audit.lock" ]]; then
    _ok "sentinel file removed"
else
    _bad "sentinel file still exists after remove"
fi
if grep -q '"kind":"curator_sentinel_removed"' "$FIX/ambient.jsonl" 2>/dev/null; then
    _ok "curator_sentinel_removed event emitted"
else
    _bad "curator_sentinel_removed event missing"
fi

# ── Test 6: EXIT trap auto-removes ─────────────────────────────────────────
echo "Test 6: EXIT trap auto-removes on subshell exit..."
(
    # shellcheck source=/dev/null
    source "$LIB"
    _create_curator_sentinel "handoff"
    _setup_sentinel_trap "handoff"
    # Subshell exits here; trap should fire
)
if [[ ! -f "$FIX/.curator-opus-handoff.lock" ]]; then
    _ok "sentinel auto-removed via EXIT trap"
else
    _bad "EXIT trap did not remove sentinel"
fi

# ── Test 7: _curator_sentinel_alive ────────────────────────────────────────
echo "Test 7: _curator_sentinel_alive..."
# Create with our own PID
(
    # shellcheck source=/dev/null
    source "$LIB"
    _create_curator_sentinel "deliberator"
    if _curator_sentinel_alive "deliberator"; then
        echo "  ✓ alive-check returns 0 for live sentinel" >&2
    else
        echo "  ✗ alive-check returned non-zero for live sentinel" >&2
        exit 1
    fi
    # Overwrite with a dead PID
    echo "1" > "$FIX/.curator-opus-deliberator.lock"
    if ! _curator_sentinel_alive "deliberator"; then
        echo "  ✓ alive-check returns non-zero for dead PID" >&2
    else
        echo "  ✗ alive-check returned 0 for dead PID" >&2
        exit 1
    fi
)
if (( $? == 0 )); then
    _ok "alive-check works for live + dead PIDs"
    # Clean up sentinel created above
    rm -f "$FIX/.curator-opus-deliberator.lock"
else
    _bad "alive-check failed"
fi

# ── Cleanup ────────────────────────────────────────────────────────────────
rm -rf "$FIX"
unset CHUMP_LOCK_DIR

echo
echo "Results: ${_pass} passed, ${_fail} failed"
if (( _fail > 0 )); then exit 1; fi
echo "✓ All META-163 curator-sentinel tests passed"
