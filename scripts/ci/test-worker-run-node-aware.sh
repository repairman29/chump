#!/usr/bin/env bash
# test-worker-run-node-aware.sh — INFRA-3659 smoke test.
#
# Verifies scripts/dispatch/worker-run.sh is node-agnostic (no hardcoded
# /root path baked into REPO_ROOT/CHUMP_REPO — that hardcoding is exactly
# what forced hand-placed cj-worker*-run.sh snowflakes on non-root nodes)
# and that it auto-computes CARGO_BUILD_JOBS from nproc / active-worker-count
# instead of relying on a hand-edited ~/.cargo/config.toml override.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/dispatch/worker-run.sh"

[[ -f "$SCRIPT" ]] || { echo "FAIL: $SCRIPT not found"; exit 1; }

PASS=0; FAIL=0
ok()   { echo "PASS: $1"; PASS=$((PASS+1)); }
bad()  { echo "FAIL: $1"; FAIL=$((FAIL+1)); }

# 1. No hardcoded /root/Projects/chump path left in the script body.
if grep -q '/root/Projects/chump' "$SCRIPT"; then
    bad "worker-run.sh still hardcodes /root/Projects/chump (not node-agnostic)"
else
    ok "worker-run.sh has no hardcoded /root/Projects/chump path"
fi

# 2. REPO_ROOT is derived from the script's own location.
if grep -q 'BASH_SOURCE\[0\]' "$SCRIPT" && grep -q 'REPO_ROOT=' "$SCRIPT"; then
    ok "worker-run.sh derives REPO_ROOT from its own on-disk location"
else
    bad "worker-run.sh does not derive REPO_ROOT from BASH_SOURCE"
fi

# 3. CARGO_BUILD_JOBS auto-computation: replicate the exact snippet as a
#    probe (mirrors test-run-fleet-core-cap.sh's pattern) since the real
#    script execs worker.sh (which would try to run a fleet loop).
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
PROBE="$TMP/probe.sh"
cat > "$PROBE" <<'PROBE_EOF'
#!/usr/bin/env bash
set -uo pipefail
_cores="${1:?}"
_workers_up="${2:?}"
[ "${_workers_up:-0}" -lt 1 ] && _workers_up=1
_auto_jobs=$(( _cores / _workers_up ))
[ "$_auto_jobs" -lt 1 ] && _auto_jobs=1
CARGO_BUILD_JOBS="${CARGO_BUILD_JOBS:-$_auto_jobs}"
echo "CARGO_BUILD_JOBS=$CARGO_BUILD_JOBS"
PROBE_EOF
chmod +x "$PROBE"

out="$("$PROBE" 4 4)"
[[ "$out" == "CARGO_BUILD_JOBS=1" ]] && ok "4 cores / 4 active workers -> CARGO_BUILD_JOBS=1" || bad "expected CARGO_BUILD_JOBS=1, got $out"

out="$("$PROBE" 8 2)"
[[ "$out" == "CARGO_BUILD_JOBS=4" ]] && ok "8 cores / 2 active workers -> CARGO_BUILD_JOBS=4" || bad "expected CARGO_BUILD_JOBS=4, got $out"

out="$(CARGO_BUILD_JOBS=9 "$PROBE" 4 1)"
[[ "$out" == "CARGO_BUILD_JOBS=9" ]] && ok "explicit CARGO_BUILD_JOBS env still wins over auto-compute" || bad "expected explicit override to win, got $out"

grep -q '_cores / _workers_up' "$SCRIPT" || bad "worker-run.sh missing the nproc/active-worker CARGO_BUILD_JOBS computation"
[[ "$FAIL" -eq 0 ]] && grep -q '_cores / _workers_up' "$SCRIPT" && ok "worker-run.sh contains the INFRA-3659 auto-jobs computation"

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]] || exit 1
exit 0
