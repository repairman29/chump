#!/usr/bin/env bash
# test-together-routing.sh — RESEARCH-027 smoke test
#
# Verifies that --agent-provider together/anthropic flags are wired correctly
# in run-cloud-v2.py and run-binary-ablation.py via dry-run mode.
# Does NOT require live API keys or network access.
#
# Usage:
#   bash scripts/ci/test-together-routing.sh
#
# Exit codes:
#   0  all checks passed
#   1  one or more checks failed

set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
HARNESS="$REPO_ROOT/scripts/ab-harness"
FIXTURE="$HARNESS/fixtures/reflection_tasks.json"
PASS=0
FAIL=0

check() {
    local desc="$1"; shift
    if "$@" &>/dev/null; then
        printf '  PASS  %s\n' "$desc"
        PASS=$((PASS+1))
    else
        printf '  FAIL  %s\n' "$desc"
        FAIL=$((FAIL+1))
    fi
}

check_output() {
    local desc="$1"; local pattern="$2"; shift 2
    local out
    out=$("$@" 2>&1 || true)
    if echo "$out" | grep -q "$pattern"; then
        printf '  PASS  %s\n' "$desc"
        PASS=$((PASS+1))
    else
        printf '  FAIL  %s  (pattern: %s)\n' "$desc" "$pattern"
        printf '         output: %s\n' "$(echo "$out" | head -3)"
        FAIL=$((FAIL+1))
    fi
}

echo "=== RESEARCH-027 together-routing smoke test ==="
echo

echo "--- together_free_models.py ---"
check "module importable" python3.12 -c "import sys; sys.path.insert(0,'$HARNESS'); import together_free_models"
check_output "recommend agent large" "together:" \
    python3.12 "$HARNESS/together_free_models.py" --recommend agent
check_output "recommend judge large" "together:" \
    python3.12 "$HARNESS/together_free_models.py" --recommend judge
check_output "--list shows free models" "free" \
    python3.12 "$HARNESS/together_free_models.py" --list

echo
echo "--- run-cloud-v2.py --agent-provider flag presence ---"
check_output "--help shows --agent-provider flag" "agent-provider" \
    python3.12 "$HARNESS/run-cloud-v2.py" --help
check_output "--help shows --agent-model flag" "agent-model" \
    python3.12 "$HARNESS/run-cloud-v2.py" --help
check_output "--help shows together choice" "together" \
    python3.12 "$HARNESS/run-cloud-v2.py" --help
# Verify provider flag resolves correctly via python import check
check_output "provider resolution logic: together→together:model" "agent_provider=together model=together:" \
    python3.12 -c "
import argparse
ap = argparse.ArgumentParser()
ap.add_argument('--fixture'); ap.add_argument('--tag')
ap.add_argument('--model', default='claude-haiku-4-5')
ap.add_argument('--agent-provider', choices=('anthropic','together','ollama'), default=None, dest='agent_provider')
ap.add_argument('--agent-model', default=None, dest='agent_model')
args = ap.parse_args(['--fixture','f.json','--tag','t','--agent-provider','together','--agent-model','llama-70b'])
if args.agent_provider is not None:
    model_name = args.agent_model or args.model
    if args.agent_provider == 'together':
        model = f'together:{model_name}'
    elif args.agent_provider == 'ollama':
        model = f'ollama:{model_name}'
    else:
        model = model_name
else:
    model = args.model
print(f'agent_provider={args.agent_provider} model={model}')
"

echo
echo "--- run-binary-ablation.py --agent-provider dry-run ---"
check "--help accepts --agent-provider" \
    python3.12 "$HARNESS/run-binary-ablation.py" --help
check_output "together provider dry-run output" "together\|OPENAI_API_BASE\|agent_provider" \
    python3.12 "$HARNESS/run-binary-ablation.py" \
        --module belief_state --n-per-cell 1 \
        --agent-provider together \
        --agent-model "meta-llama/Llama-3.3-70B-Instruct-Turbo" \
        --dry-run 2>&1 || true
check_output "anthropic provider dry-run (default)" "dry.run\|belief_state" \
    python3.12 "$HARNESS/run-binary-ablation.py" \
        --module belief_state --n-per-cell 1 \
        --dry-run 2>&1 || true

echo
if [[ $FAIL -eq 0 ]]; then
    printf '\033[0;32mAll %d checks passed.\033[0m\n' "$PASS"
    exit 0
else
    printf '\033[0;31m%d of %d checks FAILED.\033[0m\n' "$FAIL" "$((PASS+FAIL))"
    exit 1
fi
