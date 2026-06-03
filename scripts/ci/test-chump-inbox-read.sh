#!/usr/bin/env bash
# scripts/ci/test-chump-inbox-read.sh
#
# INFRA-2495: regression test for chump-inbox.sh `read --no-advance` under
# `set -u`. Background: the MANDATORY pre-flight in CLAUDE.md runs
# `chump-inbox.sh read --no-advance` at every session-start. If that script
# crashes (e.g. unbound variable), the session never gets pending peer
# broadcasts and the operator has to chase down silent communication failures.
#
# The bug: scripts/coord/lib/inbox-routing.sh:resolve_inbox_targets() set a
# trap `'rm -f "$seen_file"' RETURN` with single quotes — the variable
# expansion was deferred until RETURN time, by which point `local seen_file`
# was out of scope. Under `set -u` this triggers "seen_file: unbound variable"
# and chump-inbox.sh exits non-zero.
#
# Test cases:
#   1. `bash -u chump-inbox.sh read --no-advance` rc=0
#   2. `bash chump-inbox.sh read --no-advance` (no -u) rc=0
#   3. No stderr containing "unbound variable"

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
INBOX="$REPO_ROOT/scripts/coord/chump-inbox.sh"

if [[ ! -f "$INBOX" ]]; then
    echo "FAIL: $INBOX not found" >&2
    exit 1
fi

PASS=0
FAIL=0

_assert_pass() {
    local name="$1" rc="$2" stderr="$3"
    local has_unbound=0
    if printf '%s' "$stderr" | grep -q "unbound variable"; then
        has_unbound=1
    fi
    if [[ "$rc" -eq 0 ]] && [[ "$has_unbound" -eq 0 ]]; then
        PASS=$((PASS + 1))
        echo "  PASS: $name (rc=0, no unbound-variable error)"
    else
        FAIL=$((FAIL + 1))
        echo "  FAIL: $name (rc=$rc, unbound=$has_unbound)" >&2
        echo "    stderr: $stderr" >&2
    fi
}

echo "── Test 1: read --no-advance under bash -u (the INFRA-2495 reproducer) ──"
stderr_out=$(bash -u "$INBOX" read --no-advance 2>&1 >/dev/null) || true
rc=$?
_assert_pass "bash -u inbox-read" "$rc" "$stderr_out"

echo "── Test 2: read --no-advance under default bash ──"
stderr_out=$(bash "$INBOX" read --no-advance 2>&1 >/dev/null) || true
rc=$?
_assert_pass "bash inbox-read" "$rc" "$stderr_out"

echo "── Test 3: explicit invocation via shebang ──"
stderr_out=$("$INBOX" read --no-advance 2>&1 >/dev/null) || true
rc=$?
_assert_pass "shebang inbox-read" "$rc" "$stderr_out"

echo ""
echo "── Summary ──"
echo "  PASS: $PASS"
echo "  FAIL: $FAIL"

if [[ "$FAIL" -gt 0 ]]; then
    exit 1
fi
exit 0
