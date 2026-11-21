#!/usr/bin/env bash
# scripts/ci/test-resilient-206-free-tier-provider-preserved.sh — RESILIENT-206
#
# The fleet worker's chump-local branch (scripts/dispatch/worker.sh) builds the
# per-attempt free-tier provider list before spawning `chump --execute-gap`.
#
# THE BUG (RESILIENT-206): the branch unconditionally pinned the provider list's
# model to OPENAI_MODEL. When the operator configured
#   CHUMP_FREE_TIER_PROVIDERS=devstral-2512@https://api.mistral.ai/v1:MISTRAL_API_KEY
# and left the local-dev OPENAI_MODEL=qwen2.5:14b in .env, the branch rewrote the
# list to "qwen2.5:14b@https://api.mistral.ai/v1:MISTRAL_API_KEY" — sending a
# bogus model name to the remote provider. The fleet died TRANSPORT_UNREACHABLE
# instead of using devstral.
#
# THE FIX: gate the rewrite on _model_pinned, which is 1 ONLY when an escalation
# ladder deliberately chose the model. With no ladder + a configured provider
# list, leave the list exactly as the operator set it.
#
# Strategy (mirrors test-fleet-backend-auto-detect.sh): the resolution logic
# below MUST stay in sync with the block in worker.sh. Evaluate it in a hermetic
# sub-shell across the three cases and assert the resulting CHUMP_FREE_TIER_PROVIDERS.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WORKER="$REPO_ROOT/scripts/dispatch/worker.sh"

failures=0

# Mirror of worker.sh's model resolution + provider-list rewrite.
# Inputs via env: OPENAI_MODEL, CHUMP_FREE_TIER_PROVIDERS, CHUMP_MODEL_ESCALATION_LADDER.
# Emits: "<OPENAI_MODEL>|<CHUMP_FREE_TIER_PROVIDERS>" after resolution.
resolve() {
    local openai_model="$1" providers="$2" ladder="$3"
    OPENAI_MODEL="$openai_model" \
    CHUMP_FREE_TIER_PROVIDERS="$providers" \
    CHUMP_MODEL_ESCALATION_LADDER="$ladder" \
    bash -c '
        _cl_model="${OPENAI_MODEL:-}"
        _model_pinned=0
        if [[ -n "${CHUMP_MODEL_ESCALATION_LADDER:-}" ]]; then
            IFS="," read -r -a _ladder <<< "$CHUMP_MODEL_ESCALATION_LADDER"
            _rung=0   # rung 0 for test determinism (no strike DB)
            _cl_model="${_ladder[$_rung]}"
            _model_pinned=1
        fi
        if [[ "$_model_pinned" -eq 1 && -n "$_cl_model" ]]; then
            export OPENAI_MODEL="$_cl_model"
            if [[ -n "${CHUMP_FREE_TIER_PROVIDERS:-}" ]]; then
                _prov_suffix="${CHUMP_FREE_TIER_PROVIDERS%%,*}"
                _prov_suffix="@${_prov_suffix#*@}"
                export CHUMP_FREE_TIER_PROVIDERS="${_cl_model}${_prov_suffix}"
            fi
        elif [[ -z "${CHUMP_FREE_TIER_PROVIDERS:-}" && -n "$_cl_model" ]]; then
            export OPENAI_MODEL="$_cl_model"
        fi
        echo "${OPENAI_MODEL:-}|${CHUMP_FREE_TIER_PROVIDERS:-}"
    '
}

assert_eq() {
    local got="$1" want="$2" desc="$3"
    if [[ "$got" != "$want" ]]; then
        echo "FAIL: $desc — got '$got', want '$want'"
        failures=$((failures + 1))
    fi
}

DEVSTRAL="devstral-2512@https://api.mistral.ai/v1:MISTRAL_API_KEY"

# Case A (the regression): no ladder + configured provider list + stale local
# OPENAI_MODEL → provider list UNCHANGED, local model does NOT leak into it.
got="$(resolve "qwen2.5:14b" "$DEVSTRAL" "")"
assert_eq "$got" "qwen2.5:14b|$DEVSTRAL" \
    "no ladder: CHUMP_FREE_TIER_PROVIDERS preserved verbatim; local OPENAI_MODEL not stamped onto it"

# Case B: escalation ladder active → provider list rewritten to the ladder model,
# reusing the configured @base:KEY suffix (EFFECTIVE-314 behavior, preserved).
got="$(resolve "qwen2.5:14b" "$DEVSTRAL" "glm-4.6")"
assert_eq "$got" "glm-4.6|glm-4.6@https://api.mistral.ai/v1:MISTRAL_API_KEY" \
    "ladder active: provider list re-pinned to ladder model with @base:KEY reused"

# Case C: legacy path — no provider list configured → honor OPENAI_MODEL as the
# sole model (unchanged pre-existing behavior).
got="$(resolve "qwen2.5:14b" "" "")"
assert_eq "$got" "qwen2.5:14b|" \
    "no provider list: OPENAI_MODEL honored as legacy single-model path"

# Guard: the worker source must carry the _model_pinned gate (prevents silent
# regression back to the unconditional clobber).
if ! grep -q '_model_pinned' "$WORKER" 2>/dev/null; then
    echo "FAIL: worker.sh missing _model_pinned gate (RESILIENT-206 regressed)"
    failures=$((failures + 1))
fi

if [[ $failures -gt 0 ]]; then
    echo ""
    echo "FAIL RESILIENT-206: $failures assertion(s) failed"
    exit 1
fi

echo "OK RESILIENT-206: fleet worker preserves configured CHUMP_FREE_TIER_PROVIDERS (no local-model clobber)"
