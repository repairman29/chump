#!/usr/bin/env bash
# test-speculative-on-speculative-guard.sh — INFRA-684 CI gate.
#
# Verifies that check-spec-on-spec.sh exits non-zero when a competing PR
# for the same gap is already armed for auto-merge, and exits 0 when no
# armed competitor exists.
#
# Mocks the gh CLI via a stub binary on PATH to avoid live API calls.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CHECK="$REPO_ROOT/scripts/coord/check-spec-on-spec.sh"

[[ -f "$CHECK" ]] || { echo "FAIL: check-spec-on-spec.sh not found at $CHECK"; exit 1; }
[[ -x "$CHECK" ]] || chmod +x "$CHECK"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$TMP/bin"

# ── Stub gh: armed competitor exists for INFRA-684 ────────────────────────
# Returns one PR (number=200, branch=chump/infra-684-agent-a) with autoMergeRequest set.
# OWN_PR is 201 — excluded from the results.
cat >"$TMP/bin/gh" <<'STUB'
#!/usr/bin/env bash
# Stub gh for test-1/test-2: armed competitor at PR #200, our PR is #201
if [[ "$*" == *"pr list"* && "$*" == *"INFRA-684"* ]]; then
    # Return PR #200 (armed) — select filter for .number != 201 keeps it
    echo '[{"number":200,"headRefName":"chump/infra-684-agent-a","autoMergeRequest":{"mergeMethod":"squash"}}]'
    exit 0
fi
exit 0
STUB
chmod +x "$TMP/bin/gh"

# ── Test 1: armed competitor present → check-spec-on-spec.sh must exit 1 ──
if PATH="$TMP/bin:$PATH" bash "$CHECK" INFRA-684 201 >/dev/null 2>&1; then
    echo "FAIL test-1: check-spec-on-spec.sh should exit non-zero when competing armed PR exists"
    exit 1
fi
output=$(PATH="$TMP/bin:$PATH" bash "$CHECK" INFRA-684 201 2>&1 || true)
if ! echo "$output" | grep -q "200"; then
    echo "FAIL test-1: output should mention competing PR #200"
    echo "  Got: $output"
    exit 1
fi
echo "[OK] test-1: blocked when PR #200 is armed for same gap (our PR #201 excluded)"

# ── Test 2: own PR excluded — when our PR IS the armed one, no block ───────
# gh returns PR #201 with autoMergeRequest set, but OWN_PR=201 should exclude it.
cat >"$TMP/bin/gh" <<'STUB'
#!/usr/bin/env bash
# Stub gh for test-2: our PR #201 is armed, no competitors
if [[ "$*" == *"pr list"* && "$*" == *"INFRA-684"* ]]; then
    # Return our own PR #201 — should be excluded by .number != 201 jq filter
    echo '[{"number":201,"headRefName":"chump/infra-684-mine","autoMergeRequest":{"mergeMethod":"squash"}}]'
    exit 0
fi
exit 0
STUB
chmod +x "$TMP/bin/gh"

if ! PATH="$TMP/bin:$PATH" bash "$CHECK" INFRA-684 201 >/dev/null 2>&1; then
    echo "FAIL test-2: check-spec-on-spec.sh should pass when only our own PR is armed"
    PATH="$TMP/bin:$PATH" bash "$CHECK" INFRA-684 201 >&2 || true
    exit 1
fi
echo "[OK] test-2: own armed PR (excluded by PR number) does not block arm"

# ── Test 3: no open PRs at all → must pass ─────────────────────────────────
cat >"$TMP/bin/gh" <<'STUB'
#!/usr/bin/env bash
# Stub gh for test-3: no open PRs for the gap
if [[ "$*" == *"pr list"* ]]; then
    echo '[]'
    exit 0
fi
exit 0
STUB
chmod +x "$TMP/bin/gh"

if ! PATH="$TMP/bin:$PATH" bash "$CHECK" INFRA-684 201 >/dev/null 2>&1; then
    echo "FAIL test-3: check-spec-on-spec.sh should pass when no open PRs exist"
    exit 1
fi
echo "[OK] test-3: no open PRs → arm is safe"

# ── Test 4: open PR exists but NOT armed → must pass ──────────────────────
# (The INFRA-193 loser sweep will close it after we arm — that's correct.)
cat >"$TMP/bin/gh" <<'STUB'
#!/usr/bin/env bash
# Stub gh for test-4: competitor PR #200 is open but NOT armed
if [[ "$*" == *"pr list"* && "$*" == *"INFRA-684"* ]]; then
    echo '[{"number":200,"headRefName":"chump/infra-684-agent-a","autoMergeRequest":null}]'
    exit 0
fi
exit 0
STUB
chmod +x "$TMP/bin/gh"

if ! PATH="$TMP/bin:$PATH" bash "$CHECK" INFRA-684 201 >/dev/null 2>&1; then
    echo "FAIL test-4: check-spec-on-spec.sh should pass when competitor PR is open but not armed"
    exit 1
fi
echo "[OK] test-4: open-but-unarmed competitor PR does not block arm"

# ── Test 5: gh not available → must exit 0 (skip gracefully) ──────────────
# Use a stub that immediately exits 127 (not found), prepended before real PATH
mkdir -p "$TMP/no-gh/bin"
cat >"$TMP/no-gh/bin/gh" <<'STUB'
#!/usr/bin/env bash
exit 127
STUB
chmod +x "$TMP/no-gh/bin/gh"
# Override so 'command -v gh' finds a gh that exits 127 — simulates unavailable gh
# by creating a stub that fails; check-spec-on-spec guards with 'command -v gh'
# but we need to test the code path where gh is truly absent. Remove the stub and
# only keep the real system PATH minus any gh.
rm "$TMP/no-gh/bin/gh"
# Now no gh in the stub dir; real system PATH may have gh; force it absent:
_real_path_no_gh="$(echo "$PATH" | tr ':' '\n' | grep -v "$(dirname "$(command -v gh 2>/dev/null || echo /nowhere)")" | tr '\n' ':' | sed 's/:$//')"
if ! PATH="$_real_path_no_gh" bash "$CHECK" INFRA-684 201 >/dev/null 2>&1; then
    echo "FAIL test-5: check-spec-on-spec.sh should exit 0 when gh is unavailable"
    exit 1
fi
echo "[OK] test-5: graceful skip when gh CLI not available"

echo ""
echo "PASS: test-speculative-on-speculative-guard (5/5 cases verified)"
