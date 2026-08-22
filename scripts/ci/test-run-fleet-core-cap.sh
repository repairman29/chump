#!/usr/bin/env bash
# test-run-fleet-core-cap.sh — INFRA-3659 smoke test.
#
# Verifies run-fleet.sh's node-core-aware clamp:
#   1. FLEET_SIZE > nproc -> clamped down to nproc
#   2. FLEET_SIZE*CARGO_BUILD_JOBS > nproc -> CARGO_BUILD_JOBS clamped down
#   3. Already-within-budget values are left untouched
#
# Does not launch run-fleet.sh itself (it spawns tmux/workers) — replicates
# the exact clamp block as a standalone probe, same pattern as
# test-run-fleet-backend-default.sh.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/dispatch/run-fleet.sh"

[[ -f "$SCRIPT" ]] || { echo "FAIL: $SCRIPT not found"; exit 1; }
grep -q "INFRA-3659" "$SCRIPT" || { echo "FAIL: run-fleet.sh missing INFRA-3659 core-cap logic"; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

PROBE="$TMP/probe.sh"
cat > "$PROBE" <<'PROBE_EOF'
#!/usr/bin/env bash
set -uo pipefail
# Args: fleet_size cargo_jobs nproc_stub
FLEET_SIZE="${1:?}"
CARGO_BUILD_JOBS="${2:?}"
_STUB_NPROC="${3:?}"
nproc() { echo "$_STUB_NPROC"; }

_fleet_nproc="$(nproc 2>/dev/null || echo 1)"
if (( FLEET_SIZE > _fleet_nproc )); then
    FLEET_SIZE="$_fleet_nproc"
fi
_fleet_max_jobs=$(( _fleet_nproc / FLEET_SIZE ))
(( _fleet_max_jobs < 1 )) && _fleet_max_jobs=1
if (( CARGO_BUILD_JOBS > _fleet_max_jobs )); then
    CARGO_BUILD_JOBS="$_fleet_max_jobs"
fi
echo "FLEET_SIZE=$FLEET_SIZE CARGO_BUILD_JOBS=$CARGO_BUILD_JOBS"
PROBE_EOF
chmod +x "$PROBE"

PASS=0; FAIL=0
check() {
    local desc="$1" expect="$2" got="$3"
    if [[ "$got" == "$expect" ]]; then
        echo "PASS: $desc"; PASS=$((PASS+1))
    else
        echo "FAIL: $desc (expected [$expect] got [$got])"; FAIL=$((FAIL+1))
    fi
}

# 1. CJ incident replay: FLEET_SIZE=14, CARGO_BUILD_JOBS=4, nproc=4 -> clamp both
out="$("$PROBE" 14 4 4)"
check "CJ replay: FLEET_SIZE clamped to nproc" "FLEET_SIZE=4 CARGO_BUILD_JOBS=1" "$out"

# 2. Already within budget: FLEET_SIZE=2, CARGO_BUILD_JOBS=2, nproc=8 -> untouched
out="$("$PROBE" 2 2 8)"
check "within-budget values untouched" "FLEET_SIZE=2 CARGO_BUILD_JOBS=2" "$out"

# 3. FLEET_SIZE within nproc but jobs too high: FLEET_SIZE=4, CARGO_BUILD_JOBS=4, nproc=4
out="$("$PROBE" 4 4 4)"
check "aggregate jobs clamped when FLEET_SIZE already <= nproc" "FLEET_SIZE=4 CARGO_BUILD_JOBS=1" "$out"

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]] || exit 1
exit 0
