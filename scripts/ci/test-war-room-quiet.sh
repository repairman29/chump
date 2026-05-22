#!/usr/bin/env bash
# scripts/ci/test-war-room-quiet.sh — INFRA-1685
#
# Regression guard for scripts/dev/war-room.sh:
#   1. On bash >= 4: invocation does not crash with `declare: -A: invalid option`
#   2. On bash < 4: emits a clear actionable error (not the cryptic `declare`
#      output) and exits 64 (EX_USAGE) so SessionStart hooks can degrade
#      gracefully instead of leaking stderr noise.
#
# The full `declare -A` → parallel-array rewrite (so war-room.sh runs natively
# on macOS bash 3.2) is tracked in INFRA-1547 / a separate gap. This test
# only locks the error-path contract.
#
# Exit: 0 = contract intact, 1 = regression

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/dev/war-room.sh"

if [[ ! -f "$SCRIPT" ]]; then
    echo "FAIL INFRA-1685: $SCRIPT not found"
    exit 1
fi

# ── 1. Native bash invocation should not crash with declare: -A error ───────
# (We don't assert exit 0 — the script may exit non-zero for other reasons
# like 'gh not available' in CI. We assert the SPECIFIC cryptic error is gone.)
out="$(bash "$SCRIPT" --short 2>&1 || true)"
if echo "$out" | grep -q 'declare: -A: invalid option'; then
    echo "FAIL INFRA-1685: war-room.sh still hits 'declare: -A: invalid option' on current bash"
    echo "  This means the bash-version precondition check is missing or not running first."
    exit 1
fi

# ── 2. Synthetic bash-3.2 invocation should emit the helpful error ──────────
# Find a bash 3.x if available (macOS /bin/bash). Skip the check otherwise.
LEGACY_BASH=""
for cand in /bin/bash /usr/bin/bash; do
    if [[ -x "$cand" ]]; then
        # shellcheck disable=SC2016  # we want the inner shell to expand BASH_VERSINFO
        v="$("$cand" -c 'echo "${BASH_VERSINFO[0]}"' 2>/dev/null || echo 99)"
        if [[ "$v" -lt 4 ]]; then
            LEGACY_BASH="$cand"
            break
        fi
    fi
done

if [[ -n "$LEGACY_BASH" ]]; then
    out="$("$LEGACY_BASH" "$SCRIPT" --short 2>&1 || true)"
    if ! echo "$out" | grep -q 'requires bash >= 4'; then
        echo "FAIL INFRA-1685: legacy-bash path missing actionable error message"
        echo "  expected substring: 'requires bash >= 4'"
        echo "  got: ${out:0:200}"
        exit 1
    fi
    # Also assert exit code 64 (EX_USAGE)
    "$LEGACY_BASH" "$SCRIPT" --short >/dev/null 2>&1 && ec=$? || ec=$?
    if [[ "$ec" -ne 64 ]]; then
        echo "FAIL INFRA-1685: legacy-bash invocation exited $ec, expected 64 (EX_USAGE)"
        exit 1
    fi
    echo "OK INFRA-1685: legacy-bash ($LEGACY_BASH) emits actionable error + exit 64"
else
    echo "SKIP: no bash < 4 available on this system to verify the error path"
fi

echo "OK INFRA-1685: war-room.sh bash-version precondition intact"
