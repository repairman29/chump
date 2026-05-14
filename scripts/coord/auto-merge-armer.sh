#!/usr/bin/env bash
# INFRA-1113: Single-owner auto-merge armer — enforces 5s spacing between
# successive arm calls to avoid GitHub secondary rate limits.
#
# All callers (bot-merge.sh, pr-rescue.sh) delegate here instead of calling
# gh pr merge --auto directly. One process = one rate-limit signature.
#
# Usage:
#   auto-merge-armer.sh --pr <N> [--pr <N> ...] [--repo <owner/repo>]
#
# Exit codes:
#   0 — all PRs armed (or already armed)
#   1 — bad args / unresolvable repo
#   2 — arm failed after retries on at least one PR

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
LOCKS_DIR="${REPO_ROOT}/.chump-locks"

# shellcheck source=lib/github.sh
source "${SCRIPT_DIR}/lib/github.sh"
export CHUMP_GH_SCRIPT="auto-merge-armer.sh"

# INFRA-1113: min wall-clock seconds between successive gh pr merge --auto calls.
ARM_SPACING_S="${CHUMP_AUTO_MERGE_SPACING_S:-5}"

REPO="${GITHUB_REPOSITORY:-}"
PR_NUMS=()

# ── Args ──────────────────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        --pr)   PR_NUMS+=("$2"); shift 2 ;;
        --repo) REPO="$2";       shift 2 ;;
        *) echo "[auto-merge-armer] ERROR: unknown arg: $1" >&2; exit 1 ;;
    esac
done

if [[ ${#PR_NUMS[@]} -eq 0 ]]; then
    echo "[auto-merge-armer] ERROR: at least one --pr <N> required." >&2
    exit 1
fi

# ── Resolve repo ──────────────────────────────────────────────────────────────
if [[ -z "${REPO}" ]]; then
    REPO="$(git -C "${REPO_ROOT}" remote get-url origin 2>/dev/null \
        | sed 's|.*github.com[:/]||;s|.git$||' || true)"
fi
if [[ -z "${REPO}" ]]; then
    echo "[auto-merge-armer] ERROR: Could not determine GITHUB_REPOSITORY." >&2
    exit 1
fi

mkdir -p "${LOCKS_DIR}" 2>/dev/null || true

# ── Helpers ───────────────────────────────────────────────────────────────────
emit_ambient() {
    local kind="$1" pr_num="$2" detail="${3:-}"
    local ts
    ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf '{"ts":"%s","kind":"%s","pr":%s,"detail":"%s"}\n' \
        "${ts}" "${kind}" "${pr_num}" "${detail}" \
        >> "${LOCKS_DIR}/ambient.jsonl" 2>/dev/null || true
}

# Arm with secondary-rate-limit-aware retry (mirrors gh_with_backoff in bot-merge.sh).
arm_with_retry() {
    local pr_num="$1"
    local -a delays=(60 120 240)
    local attempt=0 rc tmpout

    while true; do
        tmpout="$(mktemp)"
        set +e
        gh pr merge "${pr_num}" --repo "${REPO}" --auto --squash >"${tmpout}" 2>&1
        rc=$?
        set -e

        if [[ $rc -eq 0 ]]; then
            rm -f "${tmpout}"
            return 0
        fi

        if grep -qi "secondary rate limit\|rate limit already exceeded" "${tmpout}" \
                && [[ $attempt -lt 3 ]]; then
            local sleep_secs=${delays[$attempt]}
            rm -f "${tmpout}"
            attempt=$(( attempt + 1 ))
            echo "[auto-merge-armer] PR #${pr_num}: secondary rate limit — sleeping ${sleep_secs}s (retry ${attempt}/3)…" >&2
            sleep "${sleep_secs}"
            continue
        fi

        cat "${tmpout}" >&2
        rm -f "${tmpout}"
        return "$rc"
    done
}

# ── Main ──────────────────────────────────────────────────────────────────────
LAST_ARM_TS=0
ANY_FAILED=0

for PR_NUM in "${PR_NUMS[@]}"; do
    # Enforce spacing between successive arm calls.
    _now="$(date -u +%s)"
    _since=$(( _now - LAST_ARM_TS ))
    if [[ $LAST_ARM_TS -gt 0 && $_since -lt $ARM_SPACING_S ]]; then
        _wait=$(( ARM_SPACING_S - _since ))
        echo "[auto-merge-armer] Rate spacing: sleeping ${_wait}s before next arm…"
        sleep "${_wait}"
    fi

    # Skip already-armed PRs — zero GraphQL cost.
    _already="$(chump_gh api "repos/${REPO}/pulls/${PR_NUM}" \
        --jq '.auto_merge != null' 2>/dev/null || echo 'false')"
    if [[ "${_already}" == "true" ]]; then
        echo "[auto-merge-armer] PR #${PR_NUM}: already armed — skipping."
        LAST_ARM_TS="$(date -u +%s)"
        continue
    fi

    # Skip closed/merged PRs.
    _state="$(chump_gh api "repos/${REPO}/pulls/${PR_NUM}" \
        --jq '.state' 2>/dev/null || echo '')"
    if [[ "${_state}" != "open" ]]; then
        echo "[auto-merge-armer] PR #${PR_NUM}: not open (state=${_state:-unknown}) — skipping."
        LAST_ARM_TS="$(date -u +%s)"
        continue
    fi

    echo "[auto-merge-armer] Arming auto-merge for PR #${PR_NUM}…"
    if arm_with_retry "${PR_NUM}"; then
        emit_ambient "auto_merge_armed" "${PR_NUM}" \
            "script=auto-merge-armer.sh spacing=${ARM_SPACING_S}s"
        echo "[auto-merge-armer] PR #${PR_NUM}: armed."
    else
        emit_ambient "auto_merge_arm_failed" "${PR_NUM}" \
            "script=auto-merge-armer.sh attempt=${attempt:-0}"
        echo "[auto-merge-armer] ERROR: PR #${PR_NUM}: arm failed." >&2
        ANY_FAILED=1
    fi

    LAST_ARM_TS="$(date -u +%s)"
done

[[ $ANY_FAILED -eq 0 ]] || exit 2
echo "[auto-merge-armer] Done."
