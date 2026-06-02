#!/usr/bin/env bash
# INFRA-2274 (e): test-consensus-merge-gate.sh — assert bot-merge.sh's
# INFRA-2274 consensus gate behaves correctly in 4 modes:
#
#   (i)   shadow mode + verdict!=PASSED → logs would_block, proceeds
#   (ii)  enforce mode + verdict=PASSED → emits approved, proceeds
#   (iii) enforce mode + verdict!=PASSED → emits blocked, fails
#   (iv)  bypass env set → skips gate, emits consensus_bypass_used
#
# Strategy: extract the gate block from bot-merge.sh into a temp script with
# mocked TARGET_PR, REPO_ROOT, AMBIENT, and `chump` binary (a fake printing
# the expected "verdict=X" line). This sidesteps the need to spin up a real
# PR + actually run the entire bot-merge pipeline.
#
# Pairs with: scripts/coord/bot-merge.sh (the gate insertion).

set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
TMPDIR_TEST="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_TEST"' EXIT

# ── Extract the gate block into a runnable harness ────────────────────────────
# Pull the lines between the two known sentinel comments. If the gate block
# was renamed/removed, the test fails fast (which is the desired signal —
# the test exists specifically to detect that breakage).
BOT_MERGE="$REPO_ROOT/scripts/coord/bot-merge.sh"
if [[ ! -f "$BOT_MERGE" ]]; then
    echo "FAIL: bot-merge.sh not found at $BOT_MERGE" >&2
    exit 1
fi

GATE_START="# ── INFRA-2274 Consensus merge gate"
GATE_END="# ── 6.5 Code-reviewer agent gate"

if ! grep -qF "$GATE_START" "$BOT_MERGE"; then
    echo "FAIL: bot-merge.sh missing INFRA-2274 gate start sentinel" >&2
    exit 1
fi
if ! grep -qF "$GATE_END" "$BOT_MERGE"; then
    echo "FAIL: bot-merge.sh missing INFRA-2274 gate end sentinel" >&2
    exit 1
fi

# Extract the lines between sentinels (exclusive of end sentinel).
GATE_BODY="$TMPDIR_TEST/gate_body.sh"
awk -v start="$GATE_START" -v end="$GATE_END" '
    index($0, start) { capture=1 }
    capture && index($0, end) { capture=0 }
    capture { print }
' "$BOT_MERGE" > "$GATE_BODY"

if [[ ! -s "$GATE_BODY" ]]; then
    echo "FAIL: extracted gate body is empty" >&2
    exit 1
fi

# ── Build a runnable harness that supplies the gate's dependencies ────────────
make_harness() {
    local mode="$1" verdict="$2" bypass_reason="${3:-}"
    local out="$TMPDIR_TEST/harness_${mode}_${verdict}.sh"
    cat > "$out" <<HARNESS_EOF
#!/usr/bin/env bash
set -uo pipefail

# Stubs for bot-merge primitives the gate calls.
stage_start() { echo "[stage_start] \$*"; }
stage_done()  { echo "[stage_done]"; }
green()  { echo "[green]  \$*"; }
yellow() { echo "[yellow] \$*"; }
red()    { echo "[red]    \$*"; }
info()   { echo "[info]   \$*"; }
_ambient_write() {
    local log_path="\$1"; local json_line="\$2"
    printf '%s\n' "\$json_line" >> "\$log_path" 2>/dev/null || true
}

# Gate inputs.
TARGET_PR=12345
REPO_ROOT="$TMPDIR_TEST"
GAP_IDS=(INFRA-9999)
export CHUMP_AMBIENT_LOG="$TMPDIR_TEST/ambient_${mode}_${verdict}.jsonl"
export CHUMP_SESSION_ID="test-session-${mode}-${verdict}"
export CHUMP_CONSENSUS_MERGE_GATE="${mode}"
HARNESS_EOF

    if [[ -n "$bypass_reason" ]]; then
        cat >> "$out" <<HARNESS_EOF
export CHUMP_OPERATOR_CONSENSUS_BYPASS="${bypass_reason}"
HARNESS_EOF
    fi

    # Fake chump binary that prints the desired verdict line.
    local fake_chump="$TMPDIR_TEST/chump_${mode}_${verdict}"
    cat > "$fake_chump" <<CHUMP_EOF
#!/usr/bin/env bash
# Mock chump binary — only the consensus-tally subcommand matters here.
if [[ "\${1:-}" == "consensus-tally" ]]; then
    echo "corr_id=pr-12345  yes=3  no=0  abstain=0  total=3  verdict=${verdict}"
    exit 0
fi
exit 0
CHUMP_EOF
    chmod +x "$fake_chump"

    cat >> "$out" <<HARNESS_EOF

# Override the chump-binary discovery so the gate finds our mock.
mkdir -p "\$REPO_ROOT/target/debug"
cp "${fake_chump}" "\$REPO_ROOT/target/debug/chump"

# Source the gate body. exit-on-block will bubble up.
HARNESS_EOF
    cat "$GATE_BODY" >> "$out"
    chmod +x "$out"
    echo "$out"
}

# ── Test cases ───────────────────────────────────────────────────────────────
PASS=0
FAIL=0

assert_emit() {
    local label="$1" ambient="$2" kind="$3"
    if [[ -f "$ambient" ]] && grep -q "\"kind\":\"$kind\"" "$ambient"; then
        echo "  PASS [$label] ambient contains kind=$kind"
        PASS=$((PASS + 1))
    else
        echo "  FAIL [$label] ambient missing kind=$kind"
        [[ -f "$ambient" ]] && echo "    ambient contents:" && cat "$ambient"
        FAIL=$((FAIL + 1))
    fi
}

assert_no_emit() {
    local label="$1" ambient="$2" kind="$3"
    if [[ ! -f "$ambient" ]] || ! grep -q "\"kind\":\"$kind\"" "$ambient"; then
        echo "  PASS [$label] ambient does NOT contain kind=$kind"
        PASS=$((PASS + 1))
    else
        echo "  FAIL [$label] ambient unexpectedly contains kind=$kind"
        FAIL=$((FAIL + 1))
    fi
}

# (i) shadow mode + NO_QUORUM → logs would_block, exits 0
echo "[test] (i) shadow mode + verdict=NO_QUORUM → would_block, proceeds"
H1="$(make_harness 1 NO_QUORUM)"
set +e; bash "$H1" >/dev/null 2>&1; RC=$?; set -e
AMB1="$TMPDIR_TEST/ambient_1_NO_QUORUM.jsonl"
if [[ $RC -eq 0 ]]; then
    echo "  PASS [shadow-noquorum] exit 0"; PASS=$((PASS + 1))
else
    echo "  FAIL [shadow-noquorum] expected exit 0, got $RC"; FAIL=$((FAIL + 1))
fi
assert_emit       "shadow-noquorum-emit"    "$AMB1" "consensus_gate_would_block"
assert_no_emit    "shadow-noquorum-no-blk"  "$AMB1" "consensus_gate_blocked"

# (ii) enforce mode + PASSED → emits approved, exits 0
echo "[test] (ii) enforce mode + verdict=PASSED → approved, proceeds"
H2="$(make_harness enforce PASSED)"
set +e; bash "$H2" >/dev/null 2>&1; RC=$?; set -e
AMB2="$TMPDIR_TEST/ambient_enforce_PASSED.jsonl"
if [[ $RC -eq 0 ]]; then
    echo "  PASS [enforce-passed] exit 0"; PASS=$((PASS + 1))
else
    echo "  FAIL [enforce-passed] expected exit 0, got $RC"; FAIL=$((FAIL + 1))
fi
assert_emit "enforce-passed-emit" "$AMB2" "consensus_gate_approved"

# (iii) enforce mode + FAILED → emits blocked, exits 1
echo "[test] (iii) enforce mode + verdict=FAILED → blocked, exits non-zero"
H3="$(make_harness enforce FAILED)"
set +e; bash "$H3" >/dev/null 2>&1; RC=$?; set -e
AMB3="$TMPDIR_TEST/ambient_enforce_FAILED.jsonl"
if [[ $RC -ne 0 ]]; then
    echo "  PASS [enforce-failed] exit $RC (non-zero as expected)"; PASS=$((PASS + 1))
else
    echo "  FAIL [enforce-failed] expected non-zero exit, got 0"; FAIL=$((FAIL + 1))
fi
assert_emit "enforce-failed-emit" "$AMB3" "consensus_gate_blocked"

# (iv) operator bypass env → emits consensus_bypass_used, exits 0
echo "[test] (iv) operator bypass env → consensus_bypass_used emitted, proceeds"
H4="$(make_harness enforce FAILED "emergency hotfix during outage")"
set +e; bash "$H4" >/dev/null 2>&1; RC=$?; set -e
AMB4="$TMPDIR_TEST/ambient_enforce_FAILED.jsonl"
# H4 uses same mode/verdict as H3 — overwrite a fresh ambient for clarity:
unset CHUMP_AMBIENT_LOG
# Re-run H4 with a clean ambient path to assert bypass behaviour cleanly.
AMB4="$TMPDIR_TEST/ambient_bypass.jsonl"
H4B="$TMPDIR_TEST/harness_bypass.sh"
{
    sed -e "s|ambient_enforce_FAILED|ambient_bypass|g" "$H4"
} > "$H4B"
chmod +x "$H4B"
set +e; bash "$H4B" >/dev/null 2>&1; RC=$?; set -e
if [[ $RC -eq 0 ]]; then
    echo "  PASS [bypass] exit 0 (bypass proceeds even when verdict=FAILED)"; PASS=$((PASS + 1))
else
    echo "  FAIL [bypass] expected exit 0, got $RC"; FAIL=$((FAIL + 1))
fi
assert_emit       "bypass-emit"      "$AMB4" "consensus_bypass_used"
assert_no_emit    "bypass-no-block"  "$AMB4" "consensus_gate_blocked"

# ── (v) INFRA-2421: fleet launcher propagates CHUMP_CONSENSUS_MERGE_GATE ─────
# Assert that scripts/dispatch/run-fleet.sh worker_env contains the var so
# the gate runs fleet-wide without requiring each operator to set it manually.
echo "[test] (v) run-fleet.sh worker_env contains CHUMP_CONSENSUS_MERGE_GATE"
RUN_FLEET="$REPO_ROOT/scripts/dispatch/run-fleet.sh"
if [[ ! -f "$RUN_FLEET" ]]; then
    echo "  FAIL [launcher-gate] run-fleet.sh not found at $RUN_FLEET"; FAIL=$((FAIL + 1))
else
    # The value must appear inside the worker_env=( ... ) block.
    # We match the exact var name to avoid false positives from comments.
    # Use /^\)/ (bare ) at line-start) to end the block so lines containing )
    # inside the array body (e.g. ${VAR:+"..."}) don't prematurely stop extraction.
    if awk '/^worker_env=\(/{in_block=1} in_block && /^\)/{in_block=0} in_block{print}' \
            "$RUN_FLEET" | grep -q 'CHUMP_CONSENSUS_MERGE_GATE'; then
        echo "  PASS [launcher-gate] worker_env contains CHUMP_CONSENSUS_MERGE_GATE"; PASS=$((PASS + 1))
    else
        echo "  FAIL [launcher-gate] worker_env in run-fleet.sh missing CHUMP_CONSENSUS_MERGE_GATE"
        echo "  (INFRA-2421: shadow mode must be activated in the fleet launcher)"
        FAIL=$((FAIL + 1))
    fi
    # Also assert that the default value is not 0 or unset (i.e. shadow or enforce).
    if awk '/^worker_env=\(/{in_block=1} in_block && /^\)/{in_block=0} in_block{print}' \
            "$RUN_FLEET" | grep -q 'CHUMP_CONSENSUS_MERGE_GATE=.*:-[1e]'; then
        echo "  PASS [launcher-gate-default] default is shadow (1) or enforce"; PASS=$((PASS + 1))
    else
        echo "  FAIL [launcher-gate-default] CHUMP_CONSENSUS_MERGE_GATE default should be 1 (shadow) or enforce"
        FAIL=$((FAIL + 1))
    fi
fi

# ── Summary ──────────────────────────────────────────────────────────────────
echo
echo "[test-consensus-merge-gate] PASS=$PASS FAIL=$FAIL"
if [[ $FAIL -gt 0 ]]; then
    exit 1
fi
echo "[test-consensus-merge-gate] all assertions passed"
exit 0
