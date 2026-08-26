#!/usr/bin/env bash
# scripts/git-hooks/pre-commit-shared-service.sh — INFRA-3463
#
# Shared-Service-Bypass gate. Surfaces NEW bespoke LLM-API calls added in this
# commit outside the sanctioned shared layer, steering them toward the canonical
# shared service (ProviderCascade — Rust: `provider_cascade::build_provider()`;
# shell/external: `chump llm-complete`). Registry + rationale + allowlist:
# docs/process/CANONICAL_SERVICES.md.
#
# Real incident that justifies it: INFRA-3457 — a hand-rolled `curl` + `x-api-key`
# in the code reviewer broke for every OAuth-only user because it bypassed the
# shared service that already handled the auth ladder. The contract stops the
# next one accruing silently.
#
# Enforcement (mirrors rust-first, INFRA-2522 anti-friction doctrine):
#   default                          WARN only (heuristic nudge, never blocks)
#   CHUMP_SHARED_SERVICE_BLOCK=1     block unless the commit carries a
#                                    `Shared-Service-Bypass: <reason>` trailer
#   CHUMP_SHARED_SERVICE_CHECK=0     disable entirely (test fixtures / escape hatch)

set -uo pipefail

[[ "${CHUMP_SHARED_SERVICE_CHECK:-1}" == "0" ]] && exit 0

# Files legitimately allowed to make direct LLM calls (kept in sync with
# docs/process/CANONICAL_SERVICES.md "Legitimately-direct sites"). Also
# self-exempts this gate, its test, and docs — which CONTAIN the signal strings
# as rules/fixtures/prose, not as calls.
_is_allowlisted() {
    case "$1" in
        *.md) return 0 ;;
        scripts/git-hooks/*) return 0 ;; # hooks describe/dispatch, never make product LLM calls
        scripts/ci/test-shared-service-gate.sh) return 0 ;;
        src/provider_cascade.rs | src/local_openai.rs) return 0 ;;
        scripts/ab-harness/*) return 0 ;;
        scripts/coord/auth-status.sh | src/model_probe.rs | src/routes/health.rs | src/web_server.rs) return 0 ;;
        scripts/eval/cross-judge.sh | scripts/ci/check-providers.sh | scripts/ci/check-heartbeat-preflight.sh) return 0 ;;
    esac
    return 1
}

# High-signal markers of a bespoke LLM API call.
PATTERN='api\.anthropic\.com|api\.openai\.com|x-api-key'

FILES="$(git diff --cached --name-only --diff-filter=AM 2>/dev/null || true)"
[[ -z "$FILES" ]] && exit 0

VIOLATIONS=()
while IFS= read -r f; do
    [[ -z "$f" ]] && continue
    _is_allowlisted "$f" && continue
    # Only ADDED lines (leading '+', excluding the '+++' file header).
    added_hits="$(git diff --cached -U0 -- "$f" 2>/dev/null \
        | grep -E '^\+' | grep -vE '^\+\+\+' \
        | grep -Ec "$PATTERN" || true)"
    if [[ "${added_hits:-0}" -gt 0 ]]; then
        VIOLATIONS+=("$f")
    fi
done <<< "$FILES"

((${#VIOLATIONS[@]} == 0)) && exit 0

_report() {
    echo "[shared-service] $1: new bespoke LLM-API call(s) added outside the shared service (INFRA-3463)." >&2
    for v in "${VIOLATIONS[@]}"; do echo "    - $v" >&2; done
    echo "    Prefer ProviderCascade (Rust: build_provider()) or 'chump llm-complete' (shell)." >&2
    echo "    See docs/process/CANONICAL_SERVICES.md." >&2
}

# WARN-only default — a nudge, not a wall.
if [[ "${CHUMP_SHARED_SERVICE_BLOCK:-0}" != "1" ]]; then
    _report "WARN"
    echo "    Not blocking (warn-only). Set CHUMP_SHARED_SERVICE_BLOCK=1 to enforce." >&2
    exit 0
fi

# Block mode: allow only with an audited bypass trailer (recorded in git history).
# INFRA-1521: --git-dir, not --git-common-dir — COMMIT_EDITMSG lives in the
# per-worktree gitdir; --git-common-dir reads the main checkout's stale file.
MSG_FILE="$(git rev-parse --git-dir 2>/dev/null)/COMMIT_EDITMSG"
if [[ -f "$MSG_FILE" ]] && grep -qE '^Shared-Service-Bypass:' "$MSG_FILE" 2>/dev/null; then
    echo "[shared-service] Shared-Service-Bypass trailer present — allowing (audited in the commit message)." >&2
    exit 0
fi

_report "BLOCKED (CHUMP_SHARED_SERVICE_BLOCK=1)"
echo "    To proceed intentionally, add a commit trailer:" >&2
echo "        Shared-Service-Bypass: <one-sentence reason>" >&2
exit 1
