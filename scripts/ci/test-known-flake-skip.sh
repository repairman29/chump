#!/usr/bin/env bash
# CI test for INFRA-1167: known-flake --skip integration in pre-push.
#
# Tests:
#   1. --skip args built from KNOWN_FLAKES.yaml
#   2. Missing tracking_gap emits WARN but not failure
#   3. CHUMP_TEST_GATE=0 still bypasses entirely
#   4. pre-push correctly passes -- --skip <name> to cargo test

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
PRE_PUSH="${REPO_ROOT}/scripts/git-hooks/pre-push"
KNOWN_FLAKES="${REPO_ROOT}/docs/process/KNOWN_FLAKES.yaml"

ok()   { echo "  [ok] $*"; }
fail() { echo "  [FAIL] $*" >&2; exit 1; }

echo "[test-known-flake-skip] INFRA-1167 — known-flake skip integration"

# ── 1. pre-push sources KNOWN_FLAKES.yaml for --skip args ─────────────────────
echo
echo "[1. pre-push reads KNOWN_FLAKES.yaml for --skip list]"
if grep -q "_SKIP_ARGS" "$PRE_PUSH"; then
    ok "pre-push builds _SKIP_ARGS from KNOWN_FLAKES.yaml"
else
    fail "pre-push does not build _SKIP_ARGS — INFRA-1167 not wired"
fi
if grep -q '"--skip"' "$PRE_PUSH" || grep -q '"--skip"' "$PRE_PUSH" || grep -q '("--skip"' "$PRE_PUSH"; then
    ok "pre-push passes --skip to cargo test"
else
    fail "pre-push does not emit --skip args"
fi

# ── 2. SKIP messages emitted for each known flake ─────────────────────────────
echo
echo "[2. SKIP (known flake): messages emitted]"
if grep -q 'SKIP (known flake)' "$PRE_PUSH"; then
    ok "pre-push emits 'SKIP (known flake): <name>' for each entry"
else
    fail "pre-push does not emit SKIP messages"
fi

# ── 3. tracking_gap absence triggers WARN not failure ─────────────────────────
echo
echo "[3. Missing tracking_gap triggers WARN not FAIL]"
if grep -q "tracking_gap:" "$PRE_PUSH" && grep -q "WARN.*tracking_gap\|tracking_gap.*WARN" "$PRE_PUSH"; then
    ok "pre-push warns on missing tracking_gap without aborting"
else
    fail "pre-push does not warn on missing tracking_gap"
fi

# ── 4. All current KNOWN_FLAKES entries have tracking_gap ─────────────────────
echo
echo "[4. All KNOWN_FLAKES entries have tracking_gap:]"
_MISSING=0
while IFS= read -r test_name; do
    [[ -z "$test_name" ]] && continue
    if ! grep -A5 "test: ${test_name}" "$KNOWN_FLAKES" 2>/dev/null \
            | grep -q "tracking_gap:"; then
        echo "  WARN: '$test_name' missing tracking_gap:" >&2
        _MISSING=$(( _MISSING + 1 ))
    fi
done < <(grep -E '^[[:space:]]*-[[:space:]]*test:' "$KNOWN_FLAKES" \
    | sed -E 's/^[[:space:]]*-[[:space:]]*test:[[:space:]]+//; s/"//g; s/[[:space:]]*$//')

if [[ $_MISSING -eq 0 ]]; then
    ok "all KNOWN_FLAKES entries have tracking_gap: (discipline maintained)"
else
    echo "  [warn] $_MISSING entries missing tracking_gap: — should add one per INFRA-764"
    ok "warn-only (not a test failure per AC 6)"
fi

# ── 5. CHUMP_TEST_GATE=0 still fully bypasses ─────────────────────────────────
echo
echo "[5. CHUMP_TEST_GATE=0 remains as emergency bypass]"
if grep -q 'CHUMP_TEST_GATE.*==.*0' "$PRE_PUSH"; then
    ok "CHUMP_TEST_GATE=0 bypass path still present in pre-push"
else
    fail "CHUMP_TEST_GATE=0 bypass removed — required as emergency escape hatch"
fi

# ── 6. cargo test invocation includes _SKIP_ARGS ─────────────────────────────
echo
echo "[6. cargo test invocation passes _SKIP_ARGS]"
if grep -q '"${_SKIP_ARGS\[@\]}"' "$PRE_PUSH"; then
    ok "cargo test invocation includes \"\${_SKIP_ARGS[@]}\""
else
    fail "cargo test invocation missing \"\${_SKIP_ARGS[@]}\" expansion"
fi

echo
echo "[test-known-flake-skip] All checks passed."
