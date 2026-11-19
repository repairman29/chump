#!/usr/bin/env bash
# scripts/ci/test-merge-queue-armed.sh — INFRA-1377
#
# Verifies that GitHub Merge Queue is enabled on the main branch.
# Merge queue serializes merges through a queue, eliminating the convoy CI
# thrash pattern where every main-bump cascades CI restarts across all open PRs.
#
# Mode:
#   Default (advisory): exits 0 even if merge queue is not yet enabled; logs
#   a warning with enablement instructions. Set CHUMP_MERGE_QUEUE_STRICT=1
#   to make the check blocking (exit 1 when disabled).
#
# Usage:
#   bash scripts/ci/test-merge-queue-armed.sh
#   CHUMP_MERGE_QUEUE_STRICT=1 bash scripts/ci/test-merge-queue-armed.sh
#
# Enabling merge queue (one-time, web UI):
#   1. Go to https://github.com/repairman29/chump/settings/branches
#   2. Edit the "main" branch protection rule
#   3. Enable "Require merge queue"
#   4. Configure: merge method=Squash, grouping=All Green, max batch=5
#
# See docs/process/MERGE_QUEUE.md for full operator runbook.

set -euo pipefail

REPO_ROOT="${REPO_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || echo "$(cd "$(dirname "$0")/../.." && pwd)")}"
STRICT="${CHUMP_MERGE_QUEUE_STRICT:-0}"

PASS=0
FAIL=0
WARN=0

ok()   { printf '\033[0;32mPASS\033[0m %s\n' "$*"; PASS=$((PASS+1)); }
warn() { printf '\033[0;33mWARN\033[0m %s\n' "$*" >&2; WARN=$((WARN+1)); }
fail() { printf '\033[0;31mFAIL\033[0m %s\n' "$*" >&2; FAIL=$((FAIL+1)); }

echo "=== INFRA-1377 merge queue armed audit ==="
echo

# ── 1. Detect merge queue state via GraphQL ───────────────────────────────────
echo "[1. GitHub Merge Queue enabled on main]"

REPO="$(git -C "${REPO_ROOT}" remote get-url chump 2>/dev/null \
    | sed 's|.*github.com[:/]||;s|.git$||' \
    || git -C "${REPO_ROOT}" remote get-url origin 2>/dev/null \
    | sed 's|.*github.com[:/]||;s|.git$||' \
    || echo '')"

OWNER="${REPO%%/*}"
REPO_NAME="${REPO##*/}"

if [[ -z "${OWNER}" ]] || [[ -z "${REPO_NAME}" ]]; then
    warn "Cannot determine owner/repo from git remotes — skipping live check"
    echo "  Hint: set GITHUB_REPOSITORY=owner/repo to enable"
elif ! command -v gh >/dev/null 2>&1; then
    warn "gh CLI not available — skipping live merge queue check"
else
    MQ_RESULT="$(gh api graphql \
        -f owner="${OWNER}" -f name="${REPO_NAME}" \
        -f query='query($owner:String!,$name:String!){
          repository(owner:$owner,name:$name){
            mergeQueue(branch:"main"){
              id
              entries(first:1){totalCount}
            }}}' \
        --jq '.data.repository.mergeQueue' 2>/dev/null || echo 'null')"

    if [[ "${MQ_RESULT}" == "null" ]] || [[ -z "${MQ_RESULT}" ]]; then
        if [[ "${STRICT}" == "1" ]]; then
            fail "Merge queue is NOT enabled on main (INFRA-1377 required)"
            echo
            echo "  Enable it:"
            echo "    1. https://github.com/${OWNER}/${REPO_NAME}/settings/branches"
            echo "    2. Edit main protection rule → enable 'Require merge queue'"
            echo "    3. Method=Squash, Grouping=All Green, Max=5"
            echo "  See: docs/process/MERGE_QUEUE.md"
        else
            warn "Merge queue not yet enabled on main — advisory mode (set CHUMP_MERGE_QUEUE_STRICT=1 to make blocking)"
            warn "  Enable: https://github.com/${OWNER}/${REPO_NAME}/settings/branches → main → 'Require merge queue'"
            warn "  See: docs/process/MERGE_QUEUE.md"
        fi
    else
        ok "GitHub Merge Queue is enabled on main (${OWNER}/${REPO_NAME})"
    fi
fi

# ── 2. auto-merge-armer.sh references _detect_merge_queue (INFRA-1377) ───────
echo
echo "[2. auto-merge-armer.sh contains merge queue detection]"
ARMER="${REPO_ROOT}/scripts/coord/auto-merge-armer.sh"
if [[ -f "${ARMER}" ]]; then
    if grep -q "_detect_merge_queue" "${ARMER}"; then
        ok "auto-merge-armer.sh contains _detect_merge_queue (INFRA-1377)"
    else
        fail "auto-merge-armer.sh is missing _detect_merge_queue — INFRA-1377 not applied"
    fi

    if grep -q "MERGE_QUEUE_ACTIVE" "${ARMER}"; then
        ok "auto-merge-armer.sh respects MERGE_QUEUE_ACTIVE flag"
    else
        fail "auto-merge-armer.sh missing MERGE_QUEUE_ACTIVE gating"
    fi

    # Verify REST-direct is guarded by MERGE_QUEUE_ACTIVE != "true" check.
    # Look for: MERGE_QUEUE_ACTIVE != "true" followed closely by rest_direct_merge_if_green
    if grep -B3 "rest_direct_merge_if_green" "${ARMER}" | grep -q 'MERGE_QUEUE_ACTIVE.*!='; then
        ok "REST-direct fast path is gated by MERGE_QUEUE_ACTIVE (queue not bypassed)"
    else
        fail "REST-direct fast path is NOT gated by MERGE_QUEUE_ACTIVE — would bypass queue ordering"
    fi
else
    fail "auto-merge-armer.sh not found at ${ARMER}"
fi

# ── 3. MERGE_QUEUE.md operator runbook exists ─────────────────────────────────
echo
echo "[3. docs/process/MERGE_QUEUE.md operator runbook]"
MQDOC="${REPO_ROOT}/docs/process/MERGE_QUEUE.md"
if [[ -f "${MQDOC}" ]]; then
    # Verify it covers the key sections.
    local_pass=1
    for section in "Enable" "Bypass" "Emergency" "Disable"; do
        if ! grep -qi "${section}" "${MQDOC}"; then
            warn "MERGE_QUEUE.md may be missing '${section}' section"
            local_pass=0
        fi
    done
    if [[ "${local_pass}" -eq 1 ]]; then
        ok "MERGE_QUEUE.md present and covers key sections"
    else
        ok "MERGE_QUEUE.md present (some sections may be incomplete — see warnings)"
    fi
else
    fail "docs/process/MERGE_QUEUE.md not found — run: docs/process/MERGE_QUEUE.md"
fi

# ── 4. Synthetic: _detect_merge_queue env-var short-circuit verified in source ──
echo
echo "[4. Synthetic: CHUMP_MERGE_QUEUE_ENABLED short-circuits live detection]"
if [[ -f "${ARMER}" ]]; then
    # Verify the source has the env-var guard logic for CHUMP_MERGE_QUEUE_ENABLED.
    if grep -q 'CHUMP_MERGE_QUEUE_ENABLED.*==.*"1"' "${ARMER}" \
        && grep -q 'CHUMP_MERGE_QUEUE_ENABLED.*==.*"0"' "${ARMER}"; then
        ok "_detect_merge_queue has env-var short-circuit (CHUMP_MERGE_QUEUE_ENABLED=1/0)"
    else
        fail "_detect_merge_queue missing CHUMP_MERGE_QUEUE_ENABLED short-circuit"
    fi

    # Extract the function and test it with a minimal bash environment.
    # Use awk to grab the function body (including closing brace).
    _func_body="$(awk '/_detect_merge_queue\(\)/{found=1} found{print; ob+=gsub(/{/,"{"); cb+=gsub(/}/,"}"); if(found && ob>0 && ob==cb){exit}}' "${ARMER}")"
    if [[ -z "${_func_body}" ]]; then
        warn "Could not extract _detect_merge_queue function body — skipping runtime test"
    else
        result_on="$(CHUMP_MERGE_QUEUE_ENABLED=1 bash -c "${_func_body}"$'\n_detect_merge_queue' 2>/dev/null || echo '')"
        if [[ "${result_on}" == "true" ]]; then
            ok "_detect_merge_queue returns 'true' when CHUMP_MERGE_QUEUE_ENABLED=1"
        else
            fail "_detect_merge_queue expected 'true' with CHUMP_MERGE_QUEUE_ENABLED=1 (got: '${result_on:-empty}')"
        fi

        result_off="$(CHUMP_MERGE_QUEUE_ENABLED=0 bash -c "${_func_body}"$'\n_detect_merge_queue' 2>/dev/null || echo '')"
        if [[ "${result_off}" == "false" ]]; then
            ok "_detect_merge_queue returns 'false' when CHUMP_MERGE_QUEUE_ENABLED=0"
        else
            fail "_detect_merge_queue expected 'false' with CHUMP_MERGE_QUEUE_ENABLED=0 (got: '${result_off:-empty}')"
        fi
    fi
else
    warn "auto-merge-armer.sh not found — synthetic env test skipped"
fi

# ── Summary ───────────────────────────────────────────────────────────────────
echo
echo "=== Results: $PASS passed, $WARN warned, $FAIL failed ==="
if [[ "$FAIL" -gt 0 ]]; then
    exit 1
fi
# Advisory warnings don't block the build.
exit 0
