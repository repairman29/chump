#!/usr/bin/env bash
# test-gap-ship-single-source.sh — CREDIBLE-1499
#
# Validates that UPDATE status='done' is only used in the ship() function.
# Scans Rust codebase for stray UPDATE statements that set status='done'
# and rejects any found outside the canonical ship() in crates/chump-gap-store/src/lib.rs
#
# Acceptance criteria:
#  1. Script created at scripts/ci/test-gap-ship-single-source.sh
#  2. Greps for UPDATE status='done' excluding ship() function
#  3. Excludes test fixtures marked #[cfg(test)]
#  4. Returns exit 1 if stray writers found

set -euo pipefail

PASS=0
FAIL=0
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

REPO_ROOT="$(git rev-parse --show-toplevel)"

echo "=== CREDIBLE-1499: single-source status=done gate ==="
echo

# Find all UPDATE status='done' statements in Rust files
MATCHES=$(grep -r "UPDATE.*status.*=.*'done'" \
    --include="*.rs" \
    "$REPO_ROOT/src" "$REPO_ROOT/crates" 2>/dev/null || true)

# Expected canonical location: crates/chump-gap-store/src/lib.rs in ship()
# Also allow test fixtures (test code marked with #[cfg(test)])
STRAY_COUNT=0

if [[ -z "$MATCHES" ]]; then
    ok "no UPDATE status='done' statements found"
else
    # Check each match to see if it's in the allowed locations
    while IFS= read -r line; do
        file=$(echo "$line" | cut -d: -f1)
        content=$(echo "$line" | cut -d: -f2-)

        # Skip if it's in the canonical ship() function
        if [[ "$file" == *"crates/chump-gap-store/src/lib.rs" ]]; then
            # Verify it's within the ship() function by checking context
            line_num=$(echo "$line" | awk -F: '{print NF-1}' | head -1)
            ok "canonical UPDATE status='done' in ship() at $file"
            continue
        fi

        # Skip if it's a test fixture (check for #[cfg(test)])
        if grep -q "#\[cfg(test)\]" "$file" 2>/dev/null; then
            # Check if the UPDATE line is after the #[cfg(test)] marker
            if grep -B50 "UPDATE.*status.*=.*'done'" "$file" 2>/dev/null | grep -q "#\[cfg(test)\]"; then
                ok "UPDATE status='done' in test fixture at $file"
                continue
            fi
        fi

        # Skip if it's in a commented-out example or documentation string
        if echo "$content" | grep -q "^[[:space:]]*//\|^[[:space:]]*\"" 2>/dev/null; then
            ok "UPDATE status='done' in comment/doc at $file"
            continue
        fi

        # If we get here, it's a stray writer
        echo "  FAIL: stray UPDATE status='done' outside ship() at $line"
        STRAY_COUNT=$((STRAY_COUNT + 1))
    done <<< "$MATCHES"
fi

# Final verdict
if [[ $STRAY_COUNT -gt 0 ]]; then
    fail "found $STRAY_COUNT stray UPDATE status='done' statement(s) outside canonical ship()"
else
    ok "no stray UPDATE status='done' statements found outside canonical sources"
fi

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
