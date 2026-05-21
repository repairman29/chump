#!/usr/bin/env bash
# scripts/ci/test-migration-pipeline-gates.sh — INFRA-1581 (closes INFRA-1538)
#
# Stubs `gh` via PATH shim so the gate predicates in
# scripts/coord/chump-runner-migration-pipeline.sh can be exercised offline.
#
# For each stage we assert both gate-met and gate-unmet paths.

set -uo pipefail

PASS=0
FAIL=0
FAILS=()
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); FAILS+=("$1"); }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

PIPELINE="$REPO_ROOT/scripts/coord/chump-runner-migration-pipeline.sh"
[[ -x "$PIPELINE" ]] || { echo "[FAIL] $PIPELINE not found / not executable"; exit 1; }

echo "=== INFRA-1581 migration-pipeline gates smoke ==="

# ── Source-contract: gate fns + corrected check-runs query exist ──────────────
for fn in gate_stage_0_fast_checks_canary gate_stage_1_clippy gate_stage_2_cargo_test gate_stage_3_acp_smoke _check_job_succeeded; do
    if grep -q "^${fn}()" "$PIPELINE" || grep -q "^${fn}(" "$PIPELINE"; then
        ok "pipeline defines $fn"
    else
        fail "pipeline missing $fn"
    fi
done

if grep -q "gh api.*commits/.*check-runs" "$PIPELINE"; then
    ok "INFRA-1538 fix: uses check-runs API (job-level)"
else
    fail "INFRA-1538: still using buggy gh run list --json name"
fi

# Buggy pattern should be GONE
if grep -q "gh run list.*--workflow=ci.yml.*select(\.name==\"fast-checks\")" "$PIPELINE"; then
    fail "INFRA-1538: still has the broken run-list+select(name) pattern"
else
    ok "INFRA-1538: broken run-list pattern removed"
fi

# ── PATH-shim gh stub: serve synthetic check-runs JSON ────────────────────────
TMP="$(mktemp -d -t migration-gates.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

# Stub structure: $TMP/gh writes a check-runs payload based on env vars
# CHUMP_STUB_SUCCESS_JOBS (comma-separated job names that should be "success").
cat > "$TMP/gh" <<'STUB'
#!/usr/bin/env bash
# Stub gh: respond to 'api repos/.../commits/main' with a fake sha, and
# 'api repos/.../check-runs' with a synthetic check-runs list driven by
# CHUMP_STUB_SUCCESS_JOBS.
if [[ "$1 $2" == "api repos/repairman29/chump/commits/main" ]]; then
    echo '{"sha":"deadbeef"}'
    exit 0
fi
if [[ "$1" == "api" ]] && echo "$2" | grep -q "check-runs"; then
    # If --jq is in args, jq-process; otherwise output raw JSON
    success_jobs="${CHUMP_STUB_SUCCESS_JOBS:-}"
    # Build a check_runs array
    items=""
    sep=""
    IFS=',' read -ra jobs <<< "$success_jobs"
    for j in "${jobs[@]}"; do
        items="${items}${sep}{\"name\":\"$j\",\"conclusion\":\"success\"}"
        sep=","
    done
    payload="{\"check_runs\":[$items]}"
    # Find --jq arg if present
    jq_arg=""
    for ((i=1; i<=$#; i++)); do
        if [[ "${!i}" == "--jq" ]]; then
            j=$((i+1))
            jq_arg="${!j}"
            break
        fi
    done
    if [[ -n "$jq_arg" ]]; then
        echo "$payload" | jq -r "$jq_arg"
    else
        echo "$payload"
    fi
    exit 0
fi
exit 0
STUB
chmod +x "$TMP/gh"
export PATH="$TMP:$PATH"
export REPO_OWNER=repairman29
export REPO_NAME=chump

# Source the pipeline so we get the gate functions in scope.
# Pipeline runs commands at the top — guard against side effects.
# Use a temporary file with just the function bodies.
FN_FILE="$TMP/gates.sh"
awk '/^_check_job_succeeded/,/^}/' "$PIPELINE" > "$FN_FILE"
awk '/^gate_stage_0_fast_checks_canary/,/^}/' "$PIPELINE" >> "$FN_FILE"
awk '/^gate_stage_1_clippy/,/^}/' "$PIPELINE" >> "$FN_FILE"
awk '/^gate_stage_2_cargo_test/,/^}/' "$PIPELINE" >> "$FN_FILE"
awk '/^gate_stage_3_acp_smoke/,/^}/' "$PIPELINE" >> "$FN_FILE"
# Provide stub envs the gates expect
echo 'log() { :; }; emit() { :; }; warn() { :; }' >> "$FN_FILE"
echo 'REPO_OWNER=repairman29; REPO_NAME=chump' >> "$FN_FILE"

# Need REPO_ROOT pointing at the worktree for the ci.yml grep in gate_stage_1
export REPO_ROOT

# shellcheck source=/dev/null
source "$FN_FILE"

# ── Stage 0: fast-checks ──────────────────────────────────────────────────────
CHUMP_STUB_SUCCESS_JOBS=fast-checks gate_stage_0_fast_checks_canary
if [[ $? -eq 0 ]]; then
    ok "stage_0 gate-met: fast-checks success → advance=0"
else
    fail "stage_0 gate-met failed unexpectedly"
fi

CHUMP_STUB_SUCCESS_JOBS= gate_stage_0_fast_checks_canary
if [[ $? -ne 0 ]]; then
    ok "stage_0 gate-unmet: no success → return 1"
else
    fail "stage_0 gate-unmet returned 0"
fi

# ── Stage 1: clippy (requires CHUMP_SELF_HOSTED_ENABLED in ci.yml) ───────────
if grep -q "CHUMP_SELF_HOSTED_ENABLED" "$REPO_ROOT/.github/workflows/ci.yml" 2>/dev/null; then
    CHUMP_STUB_SUCCESS_JOBS=clippy gate_stage_1_clippy
    if [[ $? -eq 0 ]]; then
        ok "stage_1 gate-met: clippy success + var present"
    else
        fail "stage_1 gate-met failed"
    fi

    CHUMP_STUB_SUCCESS_JOBS= gate_stage_1_clippy
    if [[ $? -ne 0 ]]; then
        ok "stage_1 gate-unmet: no clippy success → return 1"
    else
        fail "stage_1 gate-unmet returned 0"
    fi
else
    echo "  SKIP: CHUMP_SELF_HOSTED_ENABLED not in ci.yml (test fixture issue)"
fi

# ── Stage 2: cargo-test ───────────────────────────────────────────────────────
CHUMP_STUB_SUCCESS_JOBS=cargo-test gate_stage_2_cargo_test
[[ $? -eq 0 ]] && ok "stage_2 gate-met" || fail "stage_2 gate-met failed"

CHUMP_STUB_SUCCESS_JOBS= gate_stage_2_cargo_test
[[ $? -ne 0 ]] && ok "stage_2 gate-unmet" || fail "stage_2 gate-unmet returned 0"

# ── Stage 3: ACP smoke ────────────────────────────────────────────────────────
CHUMP_STUB_SUCCESS_JOBS="ACP protocol smoke test (Zed / JetBrains compatible)" gate_stage_3_acp_smoke
[[ $? -eq 0 ]] && ok "stage_3 gate-met" || fail "stage_3 gate-met failed"

CHUMP_STUB_SUCCESS_JOBS= gate_stage_3_acp_smoke
[[ $? -ne 0 ]] && ok "stage_3 gate-unmet" || fail "stage_3 gate-unmet returned 0"

echo ""
echo "=== Summary: $PASS passed, $FAIL failed ==="
if (( FAIL > 0 )); then
    for f in "${FAILS[@]}"; do printf '  - %s\n' "$f"; done
    exit 1
fi
echo "PASS"
