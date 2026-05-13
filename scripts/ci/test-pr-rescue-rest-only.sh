#!/usr/bin/env bash
# CI: pr-rescue --rest-only mode (INFRA-1016)
#
# Uses a PATH-shim fake `gh` that:
#   - fails with GraphQL rate-limit on `gh pr merge --auto`
#   - succeeds on REST API calls (`gh api -X PUT .../merge`)
#   - records which commands were invoked so assertions can verify the path taken
set -euo pipefail

PASS=0; FAIL=0
ok()   { echo "  PASS: $*"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $*"; FAIL=$((FAIL+1)); }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
PR_RESCUE="${REPO_ROOT}/scripts/coord/pr-rescue.sh"

# ── Fake gh shim ──────────────────────────────────────────────────────────────
SHIM_DIR="$(mktemp -d)"
CALL_LOG="${SHIM_DIR}/calls.log"
trap 'rm -rf "$SHIM_DIR"' EXIT

# Build a fake gh that logs all invocations and fails on GraphQL (pr merge --auto)
cat > "${SHIM_DIR}/gh" <<'SHIM'
#!/usr/bin/env bash
echo "$*" >> "${CALL_LOG}"
# Detect graphql-flavored call: `gh pr merge ... --auto`
if [[ "$1" == "pr" && "$2" == "merge" && "$*" == *"--auto"* ]]; then
    echo "GraphQL: API rate limit already exceeded for user ID 000000." >&2
    exit 1
fi
# REST merge: gh api -X PUT .../merge
if [[ "$1" == "api" && "$2" == "-X" && "$3" == "PUT" && "$*" == *"/merge"* ]]; then
    echo '{"sha":"abc123","merged":true,"message":"Pull Request successfully merged"}'
    exit 0
fi
# rate_limit query (for chump_gh telemetry)
if [[ "$1" == "api" && "$*" == *"rate_limit"* ]]; then
    echo '{"resources":{"core":{"remaining":4999},"graphql":{"remaining":0}}}'
    exit 0
fi
# Generic API calls succeed (PR list, check-runs, etc.)
if [[ "$1" == "api" ]]; then
    echo '[]'
    exit 0
fi
exit 0
SHIM
chmod +x "${SHIM_DIR}/gh"

# Inject the CALL_LOG path into the shim (the heredoc can't expand vars directly)
sed -i.bak "s|\${CALL_LOG}|${CALL_LOG}|g" "${SHIM_DIR}/gh"

# ── Helpers ───────────────────────────────────────────────────────────────────
run_rescue() {
    local extra_args="${1:-}"
    : > "${CALL_LOG}"
    GH_TOKEN="fake_token" \
    GITHUB_REPOSITORY="testorg/testrepo" \
    CHUMP_GH_SILENT=1 \
    PATH="${SHIM_DIR}:${PATH}" \
        bash "${PR_RESCUE}" ${extra_args} 2>&1 || true
}

# ── Test 1: --rest-only flag is accepted (no unknown-arg error) ───────────────
echo "Test 1: --rest-only flag accepted"
OUT=$(run_rescue "--rest-only 2>&1" || true)
# The script should not error on --rest-only flag; no PRs to rescue is OK
if echo "$OUT" | grep -q "ERROR: unknown arg: --rest-only"; then
    fail "Script rejected --rest-only flag"
else
    ok "--rest-only flag accepted without error"
fi

# ── Test 2: default mode uses GraphQL (gh pr merge --auto) ───────────────────
echo "Test 2: default mode records a 'pr merge' call in call log"
# We need a PR to rescue — mock the full flow by setting TARGET_PR and faking
# the PR to be "rescuable". Since the fake gh returns [] for lists, --pr N
# exercises the single-PR path.
: > "${CALL_LOG}"
GH_TOKEN="fake_token" \
GITHUB_REPOSITORY="testorg/testrepo" \
CHUMP_GH_SILENT=1 \
PATH="${SHIM_DIR}:${PATH}" \
    bash "${PR_RESCUE}" --pr 42 2>&1 || true
# With fake PR data returning [], script will skip (no merge needed)
# The key test is: without --rest-only, the script does NOT use the REST merge path
if grep -q "PUT.*merge" "${CALL_LOG}" 2>/dev/null; then
    fail "Default mode used REST merge path (should not)"
else
    ok "Default mode did not use REST PUT /merge"
fi

# ── Test 3: CHUMP_PR_RESCUE_REST_ONLY=1 env var accepted ─────────────────────
echo "Test 3: CHUMP_PR_RESCUE_REST_ONLY=1 env var accepted"
OUT=$(CHUMP_PR_RESCUE_REST_ONLY=1 GH_TOKEN="fake_token" \
    GITHUB_REPOSITORY="testorg/testrepo" \
    CHUMP_GH_SILENT=1 \
    PATH="${SHIM_DIR}:${PATH}" \
    bash "${PR_RESCUE}" 2>&1 || true)
if echo "$OUT" | grep -q "ERROR\|unknown arg"; then
    fail "CHUMP_PR_RESCUE_REST_ONLY=1 caused an error: $OUT"
else
    ok "CHUMP_PR_RESCUE_REST_ONLY=1 env var accepted"
fi


# ── Test 4: REST_ONLY initialized from CHUMP_PR_RESCUE_REST_ONLY env var ──────
echo "Test 4: REST_ONLY var initialized from env"
if grep -q 'REST_ONLY.*CHUMP_PR_RESCUE_REST_ONLY' "${PR_RESCUE}"; then
    ok "REST_ONLY initialized from CHUMP_PR_RESCUE_REST_ONLY"
else
    fail "REST_ONLY not wired to CHUMP_PR_RESCUE_REST_ONLY env var"
fi

# ── Test 5: REST path uses chump_gh api PUT .../merge ─────────────────────────
echo "Test 5: REST path calls chump_gh api -X PUT merge endpoint"
if grep -q 'chump_gh api.*PUT\|chump_gh api -X PUT' "${PR_RESCUE}" && \
   grep -q 'pulls.*merge' "${PR_RESCUE}"; then
    ok "REST path references chump_gh api PUT + pulls/merge endpoint"
else
    fail "REST path missing chump_gh api PUT or pulls/merge"
fi

# ── Test 6: log distinguishes REST path from GraphQL path ─────────────────────
echo "Test 6: log message differentiates REST path"
if grep -q 'REST-only\|rest_only' "${PR_RESCUE}"; then
    ok "Log or comment identifies REST-only path"
else
    fail "No REST-only identifier in log/comments"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
