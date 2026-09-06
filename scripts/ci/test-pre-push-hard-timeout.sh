#!/usr/bin/env bash
# scripts/ci/test-pre-push-hard-timeout.sh — INFRA-5126 (INFRA-1861 slice)
#
# Verifies the pre-push hook's per-phase (30s) + total (90s) hard timeout:
#   1. Structural: helper functions + env knobs + 4 wrapped guards present.
#   2. Mechanism: extract the timeout-helper block and actually exercise it
#      — a phase that overruns aborts (rc=124), emits kind=prepush_timeout,
#      and the total-budget check aborts once cumulative elapsed passes the
#      total budget (exit 1), even when no single phase alone timed out.

set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HOOK="$REPO_ROOT/scripts/git-hooks/pre-push"
PASS=0; FAIL=0
ok()   { printf '  \033[0;32mPASS\033[0m %s\n' "$*"; PASS=$((PASS+1)); }
fail() { printf '  \033[0;31mFAIL\033[0m %s\n' "$*"; FAIL=$((FAIL+1)); }

echo "=== INFRA-5126 pre-push hard timeout test ==="
[ -f "$HOOK" ] || { echo "FAIL: $HOOK missing"; exit 1; }

# ---- 1. Structural checks ----

grep -q "_pp_run_timed()" "$HOOK" \
  && ok "_pp_run_timed helper present" \
  || fail "_pp_run_timed helper missing"

grep -q "_pp_check_total_budget()" "$HOOK" \
  && ok "_pp_check_total_budget helper present" \
  || fail "_pp_check_total_budget helper missing"

grep -qE '_PP_PHASE_TIMEOUT_S="\$\{CHUMP_PREPUSH_PHASE_TIMEOUT_S:-30\}"' "$HOOK" \
  && ok "default per-phase timeout is 30s (CHUMP_PREPUSH_PHASE_TIMEOUT_S override)" \
  || fail "per-phase timeout default/knob missing or not 30s"

grep -qE '_PP_TOTAL_TIMEOUT_S="\$\{CHUMP_PREPUSH_TOTAL_TIMEOUT_S:-90\}"' "$HOOK" \
  && ok "default total-hook timeout is 90s (CHUMP_PREPUSH_TOTAL_TIMEOUT_S override)" \
  || fail "total timeout default/knob missing or not 90s"

grep -q '"kind":"prepush_timeout"' "$HOOK" \
  && ok "kind=prepush_timeout event emit site present" \
  || fail "prepush_timeout event emit site missing"

# Each of these 4 fast guards must route through the timeout helper.
for phase in fmt_check fmt_gate clippy merge_tree_preview; do
    if grep -qE "_pp_run_timed $phase|_pp_check_total_budget $phase" "$HOOK"; then
        ok "phase '$phase' wired to the timeout helper"
    else
        fail "phase '$phase' not wired to the timeout helper"
    fi
done

# ---- 2. Mechanism: extract + source the helper block, exercise it live ----

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
HELPERS="$TMP/helpers.sh"
sed -n '/# INFRA-5126:BEGIN-TIMEOUT-HELPERS/,/# INFRA-5126:END-TIMEOUT-HELPERS/p' "$HOOK" > "$HELPERS"

if [[ ! -s "$HELPERS" ]]; then
    fail "could not extract timeout-helper block via BEGIN/END markers"
else
    ok "extracted timeout-helper block via BEGIN/END markers"

    export CHUMP_PREPUSH_PHASE_TIMEOUT_S=1
    export CHUMP_PREPUSH_TOTAL_TIMEOUT_S=2
    export CHUMP_AMBIENT_LOG="$TMP/ambient.jsonl"

    # shellcheck disable=SC1090
    source "$HELPERS"

    # 2a. A phase that overruns its 1s budget aborts with rc=124.
    _pp_run_timed slow_probe sleep 3
    rc=$?
    if [[ "$rc" -eq 124 ]]; then
        ok "_pp_run_timed returns 124 when the wrapped command overruns the phase budget"
    else
        fail "_pp_run_timed returned $rc (expected 124) for an overrunning command"
    fi

    if grep -q '"kind":"prepush_timeout".*"phase":"slow_probe".*"reason":"phase_timeout"' "$CHUMP_AMBIENT_LOG" 2>/dev/null; then
        ok "prepush_timeout event emitted with phase=slow_probe reason=phase_timeout"
    else
        fail "prepush_timeout event not found for the phase_timeout case"
    fi

    # 2b. A phase that finishes within budget passes through untouched.
    _pp_run_timed fast_probe true
    rc=$?
    if [[ "$rc" -eq 0 ]]; then
        ok "_pp_run_timed returns 0 for a command that finishes within budget"
    else
        fail "_pp_run_timed returned $rc (expected 0) for a fast command"
    fi

    # 2c. Total-budget check fires once cumulative elapsed passes the total
    # timeout, independent of any single phase timing out.
    sleep 3
    ( _pp_check_total_budget total_probe )
    rc=$?
    if [[ "$rc" -eq 1 ]]; then
        ok "_pp_check_total_budget aborts (exit 1) once cumulative elapsed exceeds the total budget"
    else
        fail "_pp_check_total_budget returned $rc (expected 1) once total budget was exceeded"
    fi

    if grep -q '"kind":"prepush_timeout".*"phase":"total_probe".*"reason":"total_budget_exceeded"' "$CHUMP_AMBIENT_LOG" 2>/dev/null; then
        ok "prepush_timeout event emitted with reason=total_budget_exceeded"
    else
        fail "prepush_timeout event not found for the total_budget_exceeded case"
    fi
fi

echo "=== hard-timeout: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ] || exit 1
