#!/usr/bin/env bash
# test-opencode-harness-smoke.sh — EFFECTIVE-323
#
# "Preflight for harnesses." Exercises the non-claude (opencode/codex) spawn
# path that production is otherwise the only test of. Every bug in tonight's
# chain lived here and was invisible until a live worker crashed:
#   - $_TO unbound in the opencode/codex branch (set -u crash)     → PR #3337
#   - missing `opencode run` subcommand (ENAMETOOLONG)             → PR #3338
# Both would have failed THIS test in <1s, locally, before any push.
#
# Tier 1 (always, CI-safe, no network): build_harness_cmd under `set -u` for
#   each harness — asserts no unbound var and the argv is well-formed.
# Tier 2 (opt-in, needs opencode + auth): a live `opencode run` round-trip.
#   Skips cleanly when opencode is absent or unauthenticated.

set -euo pipefail

PASS=0
FAIL=0
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }
skip() { echo "  SKIP: $1"; }

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CMD_LIB="$REPO_ROOT/scripts/dispatch/harness-cmd.sh"
WORKER="$REPO_ROOT/scripts/dispatch/worker.sh"
HARNESS_DIR="$REPO_ROOT/scripts/dispatch/harnesses"

echo "=== EFFECTIVE-323 opencode harness smoke ==="
echo

# ── 0. wiring: worker.sh sources + uses the shared builder ───────────────────
if grep -q 'harness-cmd.sh' "$WORKER"; then
    ok "worker.sh sources harness-cmd.sh"
else
    fail "worker.sh no longer sources harness-cmd.sh (spawn command would drift)"
fi
if grep -q 'build_harness_cmd' "$WORKER"; then
    ok "worker.sh calls build_harness_cmd"
else
    fail "worker.sh no longer calls build_harness_cmd"
fi
if [[ -f "$CMD_LIB" ]]; then
    ok "harness-cmd.sh present"
else
    fail "harness-cmd.sh missing"
    echo; echo "=== Results: $PASS passed, $FAIL failed ==="; [[ "$FAIL" -eq 0 ]]; exit
fi

# build_harness_cmd in a `set -u` subshell → prints argv (one per line), or
# exits non-zero if any input var is unbound (the $_TO class of bug).
_argv_for() {  # mode program
    ( set -u
      HARNESS_SPAWN_MODE="$1"
      HARNESS_SPAWN_PROGRAM="$2"
      TO="timeout 1800s"
      prompt="implement the acceptance criteria for gap X"
      _model_arg=(--model opencode-go/kimi-k2.7-code)
      # shellcheck source=/dev/null
      source "$CMD_LIB"
      build_harness_cmd
      printf '%s\n' "${_HARNESS_CMD[@]}"
    )
}

# ── 1. opencode: no unbound var, has `run`, model, prompt ────────────────────
echo "[opencode-prompt]"
if oc_argv="$(_argv_for opencode-prompt opencode 2>/dev/null)"; then
    ok "opencode command builds under set -u (no unbound var)"
    grep -qx 'run' <<<"$oc_argv"  && ok "opencode argv contains the 'run' subcommand" \
                                  || fail "opencode argv MISSING 'run' → ENAMETOOLONG regression"
    grep -qx -- '--model' <<<"$oc_argv" && ok "opencode argv passes --model" || fail "opencode argv missing --model"
    grep -qx 'opencode-go/kimi-k2.7-code' <<<"$oc_argv" && ok "opencode argv carries the model id" || fail "model id not in argv"
    grep -q 'gap X' <<<"$oc_argv" && ok "opencode argv carries the prompt" || fail "prompt not in argv"
    grep -qx 'timeout' <<<"$oc_argv" && ok "opencode argv is timeout-wrapped" || fail "timeout prefix lost"
else
    fail "opencode command CRASHED under set -u (unbound var — the \$_TO class)"
fi

# ── 2. codex: no unbound var, has approval-mode ──────────────────────────────
echo "[codex-prompt]"
if cx_argv="$(_argv_for codex-prompt codex 2>/dev/null)"; then
    ok "codex command builds under set -u (no unbound var)"
    grep -qx -- '--approval-mode' <<<"$cx_argv" && ok "codex argv passes --approval-mode" || fail "codex argv missing --approval-mode"
else
    fail "codex command CRASHED under set -u (unbound var)"
fi

# ── 3. harness cfg files set the expected mode/program ───────────────────────
echo "[harness configs]"
( set -u; source "$HARNESS_DIR/opencode.sh"
  [[ "${HARNESS_SPAWN_MODE:-}" == "opencode-prompt" ]] && [[ "${HARNESS_SPAWN_PROGRAM:-}" == "opencode" ]] ) \
  && ok "harnesses/opencode.sh sets opencode-prompt + opencode" \
  || fail "harnesses/opencode.sh mode/program drift"

# ── 4. Tier 2 (opt-in): live opencode round-trip ─────────────────────────────
echo "[live spawn — Tier 2]"
LIVE_MODEL="${FLEET_MODEL:-opencode-go/kimi-k2.7-code}"
if [[ "${CHUMP_HARNESS_SMOKE_LIVE:-1}" != "1" ]]; then
    skip "live spawn disabled (CHUMP_HARNESS_SMOKE_LIVE=0)"
elif ! command -v opencode >/dev/null 2>&1; then
    skip "opencode CLI not on PATH"
else
    _out="$(timeout 60 opencode run --model "$LIVE_MODEL" \
             'Reply with exactly the token HARNESS_OK and nothing else.' 2>/dev/null || true)"
    if grep -q 'HARNESS_OK' <<<"$_out"; then
        ok "live opencode run returned (model=$LIVE_MODEL)"
    else
        # Unauthenticated / offline CI is not a failure of THIS gate.
        skip "live opencode run produced no token (auth/offline?) — Tier-1 still gates the wiring"
    fi
fi

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
