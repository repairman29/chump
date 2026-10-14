#!/usr/bin/env bash
# scripts/ci/test-auto-close.sh — RESILIENT-1374
#
# Test the timer-driven auto-close of decomposed parent gaps when all child
# slices are done. This script:
#   1. Creates a synthetic state.db with a decomposed umbrella parent
#   2. Marks some child slices as done
#   3. Runs the timer's service command (chump gap close-decomposed)
#   4. Verifies the parent auto-closed when all children were done
#
# Exits 0 on success, non-zero on failure.

set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
CHUMP_BIN="${REPO_ROOT}/target/release/chump"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

PASS=0
FAIL=0

_check() {
    if [[ "$2" == "$3" ]]; then
        printf '  ok   %s (exit %s)\n' "$1" "$3"
        PASS=$((PASS+1))
    else
        printf '  FAIL %s (expected exit %s, got %s)\n' "$1" "$2" "$3"
        FAIL=$((FAIL+1))
    fi
}

_emitted() {
    if grep -qE "$3" "$2" 2>/dev/null; then
        printf '  ok   %s\n' "$1"
        PASS=$((PASS+1))
    else
        printf '  FAIL %s (no match /%s/ in %s)\n' "$1" "$3" "$2"
        FAIL=$((FAIL+1))
    fi
}

# Verify chump binary exists
if [[ ! -x "$CHUMP_BIN" ]]; then
    echo "FATAL: chump binary not found or not executable at $CHUMP_BIN" >&2
    exit 1
fi

echo "[test-auto-close] timer-driven auto-close of decomposed parents"

# Create a synthetic state.db with:
#   - Parent umbrella (status=decomposed)
#   - Child slices, some done, some open
CHUMP_STATE_DB="$TMP/state.db" "$CHUMP_BIN" gap reserve \
    --domain TEST \
    --title "Parent umbrella for auto-close test" \
    --priority P3 \
    --effort m \
    --no-outcome-required \
    >/dev/null 2>&1 || {
    echo "FAIL: could not create parent gap" >&2
    exit 1
}

PARENT_ID=$(CHUMP_STATE_DB="$TMP/state.db" "$CHUMP_BIN" gap list --status open --json 2>/dev/null | \
    grep -o '"id":"[^"]*"' | head -1 | cut -d'"' -f4)

if [[ -z "$PARENT_ID" ]]; then
    echo "FAIL: could not retrieve parent gap ID" >&2
    exit 1
fi

# Decompose the parent into 3 child slices
CHUMP_STATE_DB="$TMP/state.db" "$CHUMP_BIN" gap decompose "$PARENT_ID" --no-description >/dev/null 2>&1 || {
    echo "FAIL: could not decompose parent gap" >&2
    exit 1
}

# List the child slices
CHILDREN=$(CHUMP_STATE_DB="$TMP/state.db" "$CHUMP_BIN" gap list --depends-on "$PARENT_ID" --json 2>/dev/null)
CHILD_IDS=($(echo "$CHILDREN" | grep -o '"id":"[^"]*"' | cut -d'"' -f4))

if [[ ${#CHILD_IDS[@]} -lt 2 ]]; then
    echo "FAIL: decompose did not create enough child slices (got ${#CHILD_IDS[@]})" >&2
    exit 1
fi

# Mark the first (n-1) children as done
for i in $(seq 0 $((${#CHILD_IDS[@]} - 2))); do
    CHILD_ID="${CHILD_IDS[$i]}"
    CHUMP_STATE_DB="$TMP/state.db" "$CHUMP_BIN" gap ship "$CHILD_ID" >/dev/null 2>&1 || {
        echo "FAIL: could not mark child $CHILD_ID as done" >&2
        exit 1
    }
done

# Parent should still be open (not all children done yet)
PARENT_STATUS=$(CHUMP_STATE_DB="$TMP/state.db" "$CHUMP_BIN" gap show "$PARENT_ID" --json 2>/dev/null | \
    grep -o '"status":"[^"]*"' | cut -d'"' -f4)

if [[ "$PARENT_STATUS" != "decomposed" ]]; then
    echo "FAIL: parent should be decomposed before marking all children done, but is $PARENT_STATUS" >&2
    exit 1
fi

# Mark the last child as done
LAST_CHILD="${CHILD_IDS[$((${#CHILD_IDS[@]} - 1))]}"
CHUMP_STATE_DB="$TMP/state.db" "$CHUMP_BIN" gap ship "$LAST_CHILD" >/dev/null 2>&1 || {
    echo "FAIL: could not mark last child as done" >&2
    exit 1
}

# Now run the auto-close command
AMBIENT="$TMP/ambient.jsonl"
: > "$AMBIENT"
rc=0
CHUMP_STATE_DB="$TMP/state.db" CHUMP_AMBIENT_LOG="$AMBIENT" \
    "$CHUMP_BIN" gap close-decomposed >/dev/null 2>&1 || rc=$?

_check "close-decomposed exits 0 when all children are done" 0 "$rc"

# Verify parent is now done
PARENT_STATUS_AFTER=$(CHUMP_STATE_DB="$TMP/state.db" "$CHUMP_BIN" gap show "$PARENT_ID" --json 2>/dev/null | \
    grep -o '"status":"[^"]*"' | cut -d'"' -f4)

if [[ "$PARENT_STATUS_AFTER" == "done" ]]; then
    printf '  ok   parent auto-closed to status=done\n'
    PASS=$((PASS+1))
else
    printf '  FAIL parent status is %s, expected done\n' "$PARENT_STATUS_AFTER"
    FAIL=$((FAIL+1))
fi

echo
printf '[test-auto-close] %d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]] || exit 1
echo "[test-auto-close] PASS"
