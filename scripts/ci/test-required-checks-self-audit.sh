#!/usr/bin/env bash
# scripts/ci/test-required-checks-self-audit.sh — CREDIBLE-076
#
# Self-audit gate: asserts every test in the fast-checks shard that invokes
# the runner-side chump binary AND greps its stdout has the capability-guard
# pattern. Without this gate, new tests can reintroduce the 2026-05-25 wedge
# class (test fails because runner binary lags origin/main).
#
# Pattern requirement (per docs/process/CI_REQUIRED_CHECKS_DESIGN.md):
#   A binary-touching test must (a) check command -v "$CHUMP_BIN", (b) check
#   the SPECIFIC subcommand exists in the binary (capability guard), and
#   (c) skip cleanly when not present.
#
# Detection heuristic (false-positive-tolerant):
#   FLAG a file when it contains:
#     - command -v "$CHUMP_BIN"  AND
#     - "$CHUMP_BIN" <subcmd>   (a subcommand invocation)
#   BUT lacks either:
#     - 'SKIP:' line near the capability check, OR
#     - '# capability-guard-exempt:' comment near top
#
# Exemption: add this line in the first 30 lines of a file to opt out:
#   # capability-guard-exempt: <reason>

set -uo pipefail

# --strict makes the gate FAIL on flagged tests. Default mode warns only,
# so the gate ships without breaking fast-checks until existing flagged
# tests are migrated (incrementally) to the capability-guard pattern.
# Re-arm strict mode once flagged_count drops to 0 (or all are exempted).
STRICT=0
[[ "${1:-}" == "--strict" || "${CHUMP_REQUIRED_CHECKS_AUDIT_STRICT:-0}" == "1" ]] && STRICT=1

PASS=0
FAIL=0
WARN=0
FAILS=()
WARNS=()
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); FAILS+=("$1"); }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

echo "=== CREDIBLE-076 required-checks self-audit ==="

DESIGN_DOC="$REPO_ROOT/docs/process/CI_REQUIRED_CHECKS_DESIGN.md"
[[ -f "$DESIGN_DOC" ]] && ok "design doc exists" || fail "missing $DESIGN_DOC"

# Sanity: a few canonical guarded tests we expect to find
EXPECTED_GUARDED=(
    "scripts/ci/test-fleet-spec.sh"
    "scripts/ci/test-fleet-fanout.sh"
    "scripts/ci/test-rollup-semantic.sh"
    "scripts/ci/test-inspect-resume-scrap.sh"
)
for f in "${EXPECTED_GUARDED[@]}"; do
    if [[ ! -f "$REPO_ROOT/$f" ]]; then
        echo "  WARN: expected canonical test $f missing (post-rebase?)"
        continue
    fi
    if grep -qE 'capability guard|SKIP:.*(capability|not in binary)' "$REPO_ROOT/$f"; then
        ok "canonical guarded: $f"
    else
        fail "canonical $f LACKS capability-guard marker (regression of CREDIBLE-076 fix)"
    fi
done

# Main pass: scan all scripts/ci/test-*.sh
echo
echo "=== scanning scripts/ci/test-*.sh ==="
flagged=0
exempt_count=0
clean_count=0
for f in "$REPO_ROOT"/scripts/ci/test-*.sh; do
    [[ -f "$f" ]] || continue
    rel="${f#$REPO_ROOT/}"

    # Skip this self-audit file itself
    [[ "$rel" == "scripts/ci/test-required-checks-self-audit.sh" ]] && continue

    # Exempt check (first 30 lines)
    if head -30 "$f" | grep -qE '^#\s*capability-guard-exempt:'; then
        exempt_count=$((exempt_count+1))
        continue
    fi

    # Does this file invoke the chump binary AND grep its output?
    invokes=0
    greps=0
    grep -qE '"\$CHUMP_BIN"\s+\w' "$f" 2>/dev/null && invokes=1
    grep -qE 'echo\s+"\$OUT"\s*\|\s*grep|grep -q.*\$OUT' "$f" 2>/dev/null && greps=1

    # Also consider tests that capture chump output
    if [[ "$invokes" -eq 0 ]]; then
        grep -qE 'OUT=.*"\$CHUMP_BIN"' "$f" 2>/dev/null && invokes=1
    fi

    if [[ "$invokes" -eq 1 ]]; then
        # Must have capability guard markers
        if grep -qE 'capability guard|SKIP:.*(capability|not in binary|cache lag)' "$f"; then
            clean_count=$((clean_count+1))
        else
            flagged=$((flagged+1))
            if [[ "$STRICT" -eq 1 ]]; then
                fail "binary-touching test lacks capability guard: $rel"
            else
                WARN=$((WARN+1))
                WARNS+=("$rel")
            fi
        fi
    fi
done

echo
echo "=== Summary (mode: $([[ "$STRICT" -eq 1 ]] && echo strict || echo warn-only)) ==="
echo "  binary-touching tests with guard:  $clean_count"
echo "  binary-touching tests FLAGGED:     $flagged"
echo "  files with exempt comment:         $exempt_count"
echo "  PASS=$PASS FAIL=$FAIL WARN=$WARN"

if (( WARN > 0 )); then
    echo
    echo "Warnings (would FAIL in --strict mode):"
    for f in "${WARNS[@]}"; do echo "  - $f"; done | head -25
    [[ "${#WARNS[@]}" -gt 25 ]] && echo "  ... and $(( ${#WARNS[@]} - 25 )) more"
fi

if (( FAIL > 0 )); then
    echo
    echo "Failures:"
    for f in "${FAILS[@]}"; do echo "  - $f"; done
    echo
    echo "To fix: add the capability-guard pattern from"
    echo "  docs/process/CI_REQUIRED_CHECKS_DESIGN.md"
    echo "OR add a '# capability-guard-exempt: <reason>' comment in the first"
    echo "30 lines of the test if it legitimately doesn't need a guard."
    exit 1
fi

echo
[[ "$STRICT" -eq 1 ]] && echo "OK (strict)" || echo "OK (warn-only; $WARN tests flagged for migration)"
exit 0
