#!/usr/bin/env bash
# CI test for CREDIBLE-299: per-capability lifecycle gauge
# (built->merged->deployed->wired->running->doing-its-job, DONE only at stage 6).
#
# Exercises compute_capability_stage() directly with synthetic evidence —
# no systemd/git/jq I/O required, so this proves the STAGE LOGIC itself:
# a capability is never credited past the first gap in its evidence chain,
# and DONE is reserved for stage 6 (doing-its-job), never "running".

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
LIFECYCLE_SH="${REPO_ROOT}/scripts/ops/capability-lifecycle.sh"

FAIL=0
ok()   { echo "  [ok] $*"; }
fail() { echo "  [FAIL] $*" >&2; FAIL=1; }

echo "[test-capability-lifecycle] CREDIBLE-299 — per-capability lifecycle gauge"

if [[ ! -f "$LIFECYCLE_SH" ]]; then
    echo "  [FAIL] scripts/ops/capability-lifecycle.sh not found" >&2
    exit 1
fi

# Source in a subshell-safe way: strip the auto-run guard by only defining
# functions (the script itself guards main() behind a BASH_SOURCE check, so
# sourcing is safe and does not execute main).
# shellcheck disable=SC1090
source "$LIFECYCLE_SH"

if ! declare -f compute_capability_stage >/dev/null; then
    echo "  [FAIL] compute_capability_stage function not defined by capability-lifecycle.sh" >&2
    exit 1
fi

# ── 1. Nothing built -> stage 0 ───────────────────────────────────────────
echo
echo "[1. no evidence at all]"
read -r stage name < <(compute_capability_stage 0 0 0 0 0 0)
[[ "$stage" == "0" && "$name" == "not-built" ]] \
  && ok "stage=0 name=not-built" \
  || fail "expected stage=0 not-built, got stage=$stage name=$name"

# ── 2. built+merged+deployed+wired+running but NOT doing-its-job -> stage 5,
#     NOT done. This is the exact merged-not-running trap: an active unit
#     that emits nothing must never be graded as complete.
echo
echo "[2. running but not doing-its-job -> capped at 5, not done]"
read -r stage name < <(compute_capability_stage 1 1 1 1 1 0)
[[ "$stage" == "5" && "$name" == "running" ]] \
  && ok "stage=5 name=running" \
  || fail "expected stage=5 running, got stage=$stage name=$name"
done_flag="$(is_done "$stage")"
[[ "$done_flag" == "false" ]] \
  && ok "is_done=false for stage 5 (running != doing-its-job)" \
  || fail "expected is_done=false for stage 5, got $done_flag"

# ── 3. All six true -> stage 6, DONE ──────────────────────────────────────
echo
echo "[3. full lifecycle -> stage 6, DONE]"
read -r stage name < <(compute_capability_stage 1 1 1 1 1 1)
[[ "$stage" == "6" && "$name" == "doing-its-job" ]] \
  && ok "stage=6 name=doing-its-job" \
  || fail "expected stage=6 doing-its-job, got stage=$stage name=$name"
done_flag="$(is_done "$stage")"
[[ "$done_flag" == "true" ]] \
  && ok "is_done=true only at stage 6" \
  || fail "expected is_done=true for stage 6, got $done_flag"

# ── 4. Gap in the MIDDLE of the chain caps the stage at the gap, even if
#     later evidence (e.g. doing_its_job) is somehow true — a capability
#     that is deployed+running but never wired (not systemd-enabled) must
#     not be credited past "deployed".
echo
echo "[4. gap mid-chain caps stage, later true evidence ignored]"
read -r stage name < <(compute_capability_stage 1 1 1 0 1 1)
[[ "$stage" == "3" && "$name" == "deployed" ]] \
  && ok "stage=3 name=deployed (wired=0 caps it, running/doing_its_job ignored)" \
  || fail "expected stage=3 deployed, got stage=$stage name=$name"

# ── 5. built but never merged -> stage 1 ──────────────────────────────────
echo
echo "[5. built, not merged -> stage 1]"
read -r stage name < <(compute_capability_stage 1 0 0 0 0 0)
[[ "$stage" == "1" && "$name" == "built" ]] \
  && ok "stage=1 name=built" \
  || fail "expected stage=1 built, got stage=$stage name=$name"

# ── 6. is_done is false for every stage below 6 ───────────────────────────
echo
echo "[6. is_done false for stages 0..5]"
all_ok=1
for s in 0 1 2 3 4 5; do
    d="$(is_done "$s")"
    [[ "$d" == "false" ]] || { all_ok=0; fail "is_done($s) expected false, got $d"; }
done
[[ "$all_ok" == "1" ]] && ok "is_done is false for stages 0..5 (DONE reserved for stage 6)"

echo
if [[ "$FAIL" == "0" ]]; then
    echo "[test-capability-lifecycle] All checks passed."
    exit 0
else
    echo "[test-capability-lifecycle] FAILED." >&2
    exit 1
fi
