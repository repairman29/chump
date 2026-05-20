#!/usr/bin/env bash
# scripts/ci/test-self-hosted-toggle-matrix.sh — INFRA-1567
#
# Asserts each conditional `runs-on:` in the lane workflows reads its
# lane-specific var AND the master CHUMP_SELF_HOSTED_ENABLED, AND falls
# back to ubuntu-latest when either is unset/false.
#
# Pattern checked:
#   runs-on: ${{ vars.CHUMP_SELF_HOSTED_ENABLED == 'true' &&
#                vars.CHUMP_SELF_HOSTED_<LANE> != 'false' &&
#                fromJSON('["self-hosted","macos-arm64","chump-fleet"]') ||
#                'ubuntu-latest' }}

set -uo pipefail

PASS=0
FAIL=0
FAILS=()
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); FAILS+=("$1"); }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

echo "=== INFRA-1567 self-hosted per-lane toggle matrix ==="

CI="$REPO_ROOT/.github/workflows/ci.yml"
EI="$REPO_ROOT/.github/workflows/editor-integration.yml"

# ── 1. Each lane-job uses its per-lane var ────────────────────────────────────
declare -a LANES=(
    "fast-checks:CHUMP_SELF_HOSTED_FAST_CHECKS:$CI"
    "clippy:CHUMP_SELF_HOSTED_CLIPPY:$CI"
    "cargo-test:CHUMP_SELF_HOSTED_CARGO_TEST:$CI"
    "acp-smoke:CHUMP_SELF_HOSTED_ACP:$EI"
)

for entry in "${LANES[@]}"; do
    job="${entry%%:*}"
    rest="${entry#*:}"
    lane_var="${rest%%:*}"
    file="${rest##*:}"
    # Find any runs-on line referencing the per-lane var
    if grep -qE "vars\.${lane_var}[[:space:]]*!=[[:space:]]*'false'" "$file"; then
        ok "${job}: runs-on reads vars.${lane_var}"
    else
        fail "${job}: vars.${lane_var} not referenced in $file"
    fi
done

# ── 2. Master CHUMP_SELF_HOSTED_ENABLED still required (kill-switch) ─────────
# Any runs-on that opts into self-hosted MUST also check the master.
ANY_LANE_WITHOUT_MASTER=$(
    grep -nE "vars\.CHUMP_SELF_HOSTED_(FAST_CHECKS|CLIPPY|CARGO_TEST|ACP)" "$CI" "$EI" 2>/dev/null \
        | grep -v "vars.CHUMP_SELF_HOSTED_ENABLED" || true
)
if [[ -z "$ANY_LANE_WITHOUT_MASTER" ]]; then
    ok "every lane var is paired with master CHUMP_SELF_HOSTED_ENABLED"
else
    fail "lane(s) reference a per-lane var without the master:"
    echo "$ANY_LANE_WITHOUT_MASTER" | head -3 | sed 's/^/      /'
fi

# ── 3. fallback to ubuntu-latest preserved ───────────────────────────────────
if grep -qE "ubuntu-latest" "$CI"; then
    ok "ci.yml retains ubuntu-latest fallback"
else
    fail "ci.yml lost ubuntu-latest fallback"
fi

# ── 4. Doc has per-lane section ──────────────────────────────────────────────
if grep -q "Per-lane toggles (INFRA-1567" "$REPO_ROOT/docs/process/SELF_HOSTED_RUNNERS.md"; then
    ok "SELF_HOSTED_RUNNERS.md documents per-lane toggles"
else
    fail "SELF_HOSTED_RUNNERS.md missing per-lane section"
fi

# ── 5. Master kill-switch still works (no lane bypasses master==false) ──────
# Logic: when master is 'false', NO lane should route to self-hosted. The
# expression `master == 'true' && ...` ensures this — assert structurally.
for file in "$CI" "$EI"; do
    while IFS= read -r line; do
        if echo "$line" | grep -qE "vars\.CHUMP_SELF_HOSTED_(FAST_CHECKS|CLIPPY|CARGO_TEST|ACP)"; then
            if echo "$line" | grep -qE "vars\.CHUMP_SELF_HOSTED_ENABLED[[:space:]]*==[[:space:]]*'true'"; then
                : # good
            else
                fail "lane line missing 'master == true' check: ${line:0:80}"
            fi
        fi
    done < "$file"
done
ok "structural master-kill-switch guard preserved"

echo ""
echo "=== Summary: $PASS passed, $FAIL failed ==="
if (( FAIL > 0 )); then
    for f in "${FAILS[@]}"; do printf '  - %s\n' "$f"; done
    exit 1
fi
echo "PASS"
