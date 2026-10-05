#!/usr/bin/env bash
# INFRA-3579 regression guard: integrations.yml's pull_request concurrency
# group must be keyed on github.sha, not github.event.pull_request.number.
# Keying on PR number let two pushes to the same PR within the ~11min ACP
# smoke run window cancel each other's in-flight self-hosted job mid-checkout
# — indistinguishable from a checkout flake, and the actual root cause behind
# the INFRA-1655 investigation (same class as the INFRA-1852 ci.yml fix).
set -euo pipefail
ROOT="$(git rev-parse --show-toplevel)"
cd "$ROOT"

WF=".github/workflows/integrations.yml"

if [[ ! -f "$WF" ]]; then
    echo "FAIL: $WF not found" >&2
    exit 1
fi

GROUP_LINE="$(awk '/^concurrency:/{flag=1; next} flag && /^\s*group:/{print; exit}' "$WF")"

if [[ -z "$GROUP_LINE" ]]; then
    echo "FAIL: $WF has no top-level concurrency group: line" >&2
    exit 1
fi

if echo "$GROUP_LINE" | grep -q 'pull_request\.number'; then
    echo "FAIL: $WF concurrency group is keyed on pull_request.number — regression of INFRA-3579/INFRA-1852 fix" >&2
    echo "  $GROUP_LINE" >&2
    exit 1
fi

if ! echo "$GROUP_LINE" | grep -q 'github\.sha'; then
    echo "FAIL: $WF concurrency group must key pull_request runs on github.sha" >&2
    echo "  $GROUP_LINE" >&2
    exit 1
fi

echo "OK: $WF concurrency group is keyed on github.sha (INFRA-3579 fix intact)"
