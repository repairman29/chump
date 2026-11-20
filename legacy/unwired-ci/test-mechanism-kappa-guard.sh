#!/usr/bin/env bash
# test-mechanism-kappa-guard.sh — EVAL-093 advisory hook tests.
#
# Each case sets up a temp git repo, stages a synthetic diff, and runs
# scripts/ci/check-mechanism-kappa.sh. Verifies advisory fires (warn) when
# expected, stays silent when expected, and blocks (exit 1) under enforce mode.

set -euo pipefail

CHECKER="$(git rev-parse --show-toplevel)/scripts/ci/check-mechanism-kappa.sh"
[[ -x "$CHECKER" ]] || { echo "FAIL: checker not executable: $CHECKER" >&2; exit 1; }

PASS=0
FAIL=0

run_case() {
    local name="$1"
    local expect_exit="$2"
    local expect_warn="$3"  # 1 = expect WARN line, 0 = expect no WARN
    local diff_content="$4"
    local commit_msg="$5"
    local gate_mode="${6:-warn}"

    local tmpdir
    tmpdir="$(mktemp -d)"
    pushd "$tmpdir" >/dev/null
    git init -q
    git config user.email t@t
    git config user.name t
    echo "initial" > base.txt
    git add base.txt
    git commit -q -m "init"

    # Apply synthetic diff
    printf '%s\n' "$diff_content" > target.md
    git add target.md

    local msg_file
    msg_file="$(mktemp)"
    printf '%s\n' "$commit_msg" > "$msg_file"

    local actual_exit=0
    local stderr_out
    stderr_out="$(CHUMP_KAPPA_GATE="$gate_mode" "$CHECKER" --commit-msg-file "$msg_file" 2>&1 >/dev/null)" || actual_exit=$?

    local got_warn=0
    if echo "$stderr_out" | grep -q "ADVISORY (EVAL-093)"; then got_warn=1; fi

    if [[ "$actual_exit" == "$expect_exit" && "$got_warn" == "$expect_warn" ]]; then
        echo "[PASS] $name"
        PASS=$((PASS+1))
    else
        echo "[FAIL] $name: expect exit=$expect_exit warn=$expect_warn, got exit=$actual_exit warn=$got_warn"
        echo "       stderr: $stderr_out"
        FAIL=$((FAIL+1))
    fi

    rm -f "$msg_file"
    popd >/dev/null
    rm -rf "$tmpdir"
}

# Case 1: mechanism claim + |Δ|=0.30 + NO kappa → WARN, exit 0 (advisory default)
run_case "mechanism + large delta + no kappa → warn" 0 1 \
    "Found mechanism: over-compliance on gotcha tasks. delta = -0.30 across 50 trials." \
    "claim mechanism for over-compliance Δ=-0.30"

# Case 2: mechanism + large delta + κ citation in diff → silent, exit 0
run_case "mechanism + large delta + kappa in diff → silent" 0 0 \
    "Mechanism: over-compliance, delta = -0.30. Cross-judge κ = 0.72 on gotcha class (Sonnet vs Llama)." \
    "claim with kappa"

# Case 3: mechanism + large delta + κ citation in commit message → silent, exit 0
run_case "mechanism + large delta + kappa in commit msg → silent" 0 0 \
    "Mechanism explanation: delta = -0.30 due to over-compliance pattern observed across N=50 trials." \
    "Mechanism claim. Cross-judge kappa = 0.71 on gotcha fixture; Sonnet + Llama agree."

# Case 4: small delta (Δ=0.02) + mechanism → silent (delta below threshold)
run_case "mechanism + small delta → silent (below threshold)" 0 0 \
    "Found mechanism: weak interaction. delta = 0.02 trivial." \
    "small mechanism note"

# Case 5: large delta but NO mechanism language → silent (just a delta report, not a claim)
run_case "large delta + no mechanism → silent (just a delta)" 0 0 \
    "Sweep result: delta = -0.30 across 50 trials. Aggregate only; no per-class drilldown." \
    "report delta"

# Case 6: pp-style delta (-30pp) + mechanism + no kappa → WARN
run_case "pp-style delta + mechanism + no kappa → warn" 0 1 \
    "Mechanism finding: gotcha tasks regress -30pp under DeepSeek." \
    "DeepSeek -30pp gotcha mechanism claim"

# Case 7: enforce mode + violation → exit 1, WARN
run_case "enforce mode blocks violation" 1 1 \
    "Mechanism: delta = -0.30 over-compliance pattern." \
    "claim" \
    "enforce"

# Case 8: silenced mode + violation → silent, exit 0
run_case "silenced mode skips check" 0 0 \
    "Mechanism: delta = -0.30 over-compliance pattern." \
    "claim" \
    "0"

echo ""
echo "Passed: $PASS  Failed: $FAIL"
[[ "$FAIL" -eq 0 ]]
