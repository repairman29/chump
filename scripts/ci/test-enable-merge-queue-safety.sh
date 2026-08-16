#!/usr/bin/env bash
# scripts/ci/test-enable-merge-queue-safety.sh — RESILIENT-343
#
# Verifies scripts/coord/enable-merge-queue.sh's safety gates:
#   1. The script exists and defaults to dry-run (no --confirm => no mutation).
#   2. It refuses to proceed (and never attempts a mutation) when the
#      merge_group readiness gate fails.
#   3. --confirm is required to reach the mutating gh api PUT call.
#
# This is a regression gate for the "operator sign-off required" contract in
# CLAUDE.md — the enablement script must never mutate GitHub branch
# protection without an explicit --confirm from a human.

set -euo pipefail

REPO_ROOT="${REPO_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || echo "$(cd "$(dirname "$0")/../.." && pwd)")}"
SCRIPT="${REPO_ROOT}/scripts/coord/enable-merge-queue.sh"

PASS=0
FAIL=0
ok()   { printf '\033[0;32mPASS\033[0m %s\n' "$*"; PASS=$((PASS+1)); }
fail() { printf '\033[0;31mFAIL\033[0m %s\n' "$*" >&2; FAIL=$((FAIL+1)); }

echo "=== RESILIENT-343 enable-merge-queue.sh safety gate audit ==="
echo

# ── 1. Script exists and is executable ────────────────────────────────────────
echo "[1. Script presence]"
if [[ -x "${SCRIPT}" ]]; then
    ok "scripts/coord/enable-merge-queue.sh exists and is executable"
else
    fail "scripts/coord/enable-merge-queue.sh missing or not executable"
fi

# ── 2. Default (no flags) never reaches the mutating gh api PUT call ──────────
echo
echo "[2. Dry-run by default: mutation call is source-gated behind --confirm]"
if grep -q -- '--method PUT' "${SCRIPT}" && grep -B40 -- '--method PUT' "${SCRIPT}" | grep -q 'CONFIRM.*-ne 1'; then
    ok "The PUT mutation is only reachable after the CONFIRM-flag early-return"
else
    fail "Could not verify the PUT mutation is gated behind --confirm"
fi

# ── 3. Sandbox run: coverage failure aborts before touching gh ────────────────
echo
echo "[3. Sandbox: coverage-gate failure blocks the script before any gh call]"
SANDBOX="$(mktemp -d)"
trap 'rm -rf "${SANDBOX}"' EXIT

mkdir -p "${SANDBOX}/bin"
cat > "${SANDBOX}/bin/gh" <<'EOF'
#!/usr/bin/env bash
echo "gh should not have been invoked when coverage gate fails" >&2
exit 99
EOF
chmod +x "${SANDBOX}/bin/gh"

FAKE_COVERAGE="${SANDBOX}/fake-coverage.sh"
cat > "${FAKE_COVERAGE}" <<'EOF'
#!/usr/bin/env bash
echo "simulated: required check missing merge_group trigger"
exit 1
EOF
chmod +x "${FAKE_COVERAGE}"

set +e
OUTPUT="$(PATH="${SANDBOX}/bin:${PATH}" REPO_ROOT="${REPO_ROOT}" \
    LOCKS_DIR="${SANDBOX}/locks" COVERAGE_SCRIPT="${FAKE_COVERAGE}" \
    bash "${SCRIPT}" --confirm 2>&1)"
STATUS=$?
set -e

if [[ "${STATUS}" -ne 0 ]]; then
    ok "Script exits non-zero when the coverage gate fails"
else
    fail "Script exited 0 despite a failing coverage gate (STATUS=${STATUS})"
fi

if echo "${OUTPUT}" | grep -q "should not have been invoked"; then
    fail "Script invoked gh even though the coverage gate failed — unsafe"
else
    ok "Script never called gh after the coverage gate failed"
fi

# ── 4. Sandbox: readiness pass + no --confirm => dry-run report, no gh PUT ────
echo
echo "[4. Sandbox: readiness pass without --confirm reports dry-run, no mutation]"
cat > "${SANDBOX}/bin/gh" <<'EOF'
#!/usr/bin/env bash
if [[ "$1" == "api" && "$2" == "graphql" ]]; then
    echo '{"data":{"repository":{"mergeQueue":null}}}' \
      | { command -v jq >/dev/null 2>&1 && jq -r '.data.repository.mergeQueue' || echo null; }
    exit 0
fi
if [[ "$*" == *"--method PUT"* ]]; then
    echo "MUTATION ATTEMPTED WITHOUT --confirm" >&2
    exit 1
fi
echo "repairman29/chump"
exit 0
EOF
chmod +x "${SANDBOX}/bin/gh"

PASS_COVERAGE="${SANDBOX}/pass-coverage.sh"
cat > "${PASS_COVERAGE}" <<'EOF'
#!/usr/bin/env bash
echo "simulated: all required checks merge_group-wired"
exit 0
EOF
chmod +x "${PASS_COVERAGE}"

set +e
OUTPUT2="$(PATH="${SANDBOX}/bin:${PATH}" REPO_ROOT="${REPO_ROOT}" \
    LOCKS_DIR="${SANDBOX}/locks" COVERAGE_SCRIPT="${PASS_COVERAGE}" \
    bash "${SCRIPT}" 2>&1)"
STATUS2=$?
set -e

if [[ "${STATUS2}" -eq 0 ]] && echo "${OUTPUT2}" | grep -qi "DRY-RUN"; then
    ok "Readiness-pass + no --confirm produces a DRY-RUN report and exits 0"
else
    fail "Expected a DRY-RUN report on success without --confirm (status=${STATUS2})"
fi

if echo "${OUTPUT2}" | grep -q "MUTATION ATTEMPTED"; then
    fail "Script mutated branch protection without --confirm — unsafe"
else
    ok "No mutation attempted without --confirm"
fi

# ── Summary ────────────────────────────────────────────────────────────────────
echo
echo "=== Results: ${PASS} passed, ${FAIL} failed ==="
if [[ "${FAIL}" -gt 0 ]]; then
    exit 1
fi
exit 0
