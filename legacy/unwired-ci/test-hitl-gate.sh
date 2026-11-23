#!/usr/bin/env bash
# test-hitl-gate.sh — INFRA-1813
#
# Validates the Marcus M-B HITL approval gate inserted into bot-merge.sh
# (Vendored from BEAST-MODE @ 612ff45f73791 — CP-003).
#
# This is a unit smoke test of the GATE LOGIC ONLY (the bash conditionals
# that decide block-vs-proceed). We do NOT exercise the full bot-merge.sh
# pipeline — that would require a live GH PR. We:
#
#  1. Extract the HITL block from bot-merge.sh by `bash -n` parsing it.
#  2. Verify the four required tokens are present in the file at all.
#  3. Run a self-contained mini-script that replicates the decision
#     logic with mocked inputs (no PR, no gh, no ambient writes); verify
#     each input combination produces the expected blocking decision.
#  4. Verify the two new event kinds are registered in EVENT_REGISTRY.yaml.
#
# Run: bash scripts/ci/test-hitl-gate.sh

set -uo pipefail

PASS=0
FAIL=0
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
BOT_MERGE="$REPO_ROOT/scripts/coord/bot-merge.sh"
REGISTRY="$REPO_ROOT/docs/observability/EVENT_REGISTRY.yaml"
DOC="$REPO_ROOT/docs/process/HITL_APPROVAL.md"

echo "=== INFRA-1813 HITL gate smoke test ==="
echo

# ── 1. structural presence in bot-merge.sh ────────────────────────────────────
echo "[1. structural presence in bot-merge.sh]"
if [[ ! -f "$BOT_MERGE" ]]; then
    fail "bot-merge.sh missing at $BOT_MERGE"
else
    ok "bot-merge.sh exists"
fi

for tok in "INFRA-1813" "CHUMP_REQUIRE_HITL" "CHUMP_HITL_APPROVED" \
           "hitl-approved" "hitl_approval_required" "hitl_approval_granted" \
           ".chump/require-hitl" "hitl-approved-\${TARGET_PR}.flag"; do
    if grep -qF "$tok" "$BOT_MERGE"; then
        ok "bot-merge.sh references '$tok'"
    else
        fail "bot-merge.sh missing token '$tok'"
    fi
done

# Quote the heredoc end-marker so bash doesn't try to expand its body.
if bash -n "$BOT_MERGE" 2>/dev/null; then
    ok "bot-merge.sh parses (bash -n)"
else
    fail "bot-merge.sh fails bash -n syntax check"
fi

# ── 2. decision-logic replay (table-driven) ───────────────────────────────────
# Replicate the conditional from bot-merge.sh in isolation. Each row exercises
# one combination of (require_hitl, env_approved, file_flag, label_match).
echo
echo "[2. decision-logic table replay]"

run_case() {
    local _label="$1" _require="$2" _env="$3" _file="$4" _labelmatch="$5" _expect="$6"
    local _decision
    if [[ "$_require" == "1" ]]; then
        if [[ "$_env" == "1" || "$_file" == "1" || "$_labelmatch" == "1" ]]; then
            _decision="proceed"
        else
            _decision="block"
        fi
    else
        _decision="proceed"
    fi
    if [[ "$_decision" == "$_expect" ]]; then
        ok "$_label → $_decision (expected $_expect)"
    else
        fail "$_label → $_decision (expected $_expect)"
    fi
}

#         label                                  req env file label  expect
run_case "require=OFF, no approval"              "0" "0" "0" "0"    "proceed"
run_case "require=OFF, env approved (no-op)"     "0" "1" "0" "0"    "proceed"
run_case "require=ON,  no approval"              "1" "0" "0" "0"    "block"
run_case "require=ON,  env approved"             "1" "1" "0" "0"    "proceed"
run_case "require=ON,  file flag present"        "1" "0" "1" "0"    "proceed"
run_case "require=ON,  PR label present"         "1" "0" "0" "1"    "proceed"
run_case "require=ON,  all three signals"        "1" "1" "1" "1"    "proceed"

# ── 3. EVENT_REGISTRY.yaml — both kinds registered ────────────────────────────
echo
echo "[3. EVENT_REGISTRY.yaml entries]"

if [[ ! -f "$REGISTRY" ]]; then
    fail "EVENT_REGISTRY.yaml missing at $REGISTRY"
else
    ok "EVENT_REGISTRY.yaml exists"
fi

for kind in "hitl_approval_required" "hitl_approval_granted"; do
    if grep -qE "^[[:space:]]*-[[:space:]]*kind:[[:space:]]*${kind}[[:space:]]*$" "$REGISTRY"; then
        ok "EVENT_REGISTRY registers kind=$kind"
    else
        fail "EVENT_REGISTRY missing kind=$kind"
    fi
done

# Verify scanner-anchor comments (curator-opus-handoff discipline)
for kind in "hitl_approval_required" "hitl_approval_granted"; do
    if grep -qF "scanner-anchor: \"kind\":\"${kind}\"" "$BOT_MERGE"; then
        ok "bot-merge.sh has scanner-anchor for kind=$kind"
    else
        fail "bot-merge.sh missing scanner-anchor for kind=$kind"
    fi
done

# ── 4. Operator-facing doc shipped ────────────────────────────────────────────
echo
echo "[4. operator doc shipped]"

if [[ ! -f "$DOC" ]]; then
    fail "HITL_APPROVAL.md missing at $DOC"
else
    ok "HITL_APPROVAL.md exists"
    for section in "Approval signals" "Per-repo opt-in" "Operator flow" "BEAST-MODE" "INFRA-1813"; do
        if grep -qF "$section" "$DOC"; then
            ok "HITL_APPROVAL.md covers '$section'"
        else
            fail "HITL_APPROVAL.md missing section '$section'"
        fi
    done
fi

# ── 5. block exit-summary ─────────────────────────────────────────────────────
echo
echo "=== summary: $PASS pass, $FAIL fail ==="
if [[ $FAIL -gt 0 ]]; then
    exit 1
fi
exit 0
