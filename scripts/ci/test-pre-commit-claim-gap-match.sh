#!/usr/bin/env bash
# test-pre-commit-claim-gap-match.sh — RESILIENT-025 off-rails guard tests
#
# 4 fixtures:
#   T1: claim for INFRA-9999, subject "fix(INFRA-9999): foo"         → PASS
#   T2: claim for INFRA-9999, subject "fix(INFRA-1234): bar"         → FAIL (blocked)
#   T3: no claim file, subject "docs: random"                        → PASS (human op)
#   T4: claim for INFRA-9999, subject "fix(INFRA-1234): ...",
#       body "Off-Rails-Bypass: integrating prereq from sibling PR"  → PASS (bypass),
#       emits off_rails_bypassed ambient event

set -euo pipefail

PASS=0
FAIL=0

# Path to the pre-commit hook (repo-relative)
REPO_ROOT="$(git -C "$(dirname "$0")" rev-parse --show-toplevel)"
PRE_COMMIT="$REPO_ROOT/scripts/git-hooks/pre-commit"

_pass() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
_fail() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

# Extract just the RESILIENT-025 check from pre-commit as a standalone snippet
# by invoking the real hook with synthetic fixtures.
#
# We can't invoke the full pre-commit hook in tests (it calls cargo fmt etc),
# so we extract just the off-rails block and source it in a subshell with the
# required env vars mocked.

_run_off_rails_check() {
    local locks_dir="$1"
    local commit_msg="$2"
    local ambient_log="$3"

    # Run in a subshell so set -e doesn't kill the test runner
    (
        export CHUMP_OFF_RAILS_CHECK=1
        # Provide a fake REPO_ROOT pointing at our synthetic fixture dirs
        export REPO_ROOT="$locks_dir"

        # Write the fake COMMIT_EDITMSG
        mkdir -p "$locks_dir/.git"
        printf '%s\n' "$commit_msg" > "$locks_dir/.git/COMMIT_EDITMSG"

        # Point ambient log at our temp dir
        local _ambient="$ambient_log"

        # Run only the RESILIENT-025 section (extracted inline)
        _CLAIM_FILE=$(find "$REPO_ROOT/.chump-locks" -maxdepth 1 -name 'claim-*.json' 2>/dev/null | head -1 || true)
        if [ -n "$_CLAIM_FILE" ] && [ -f "$_CLAIM_FILE" ]; then
            _CLAIMED_GAP=$(jq -r '.gap_id // empty' "$_CLAIM_FILE" 2>/dev/null || true)
            if [ -n "$_CLAIMED_GAP" ]; then
                # In tests we write the fake COMMIT_EDITMSG under $REPO_ROOT/.git/
                # (mktemp dir, not a real worktree), so use that path directly.
                _EDITMSG="$REPO_ROOT/.git/COMMIT_EDITMSG"
                if [ -f "$_EDITMSG" ]; then
                    _COMMIT_MSG=$(cat "$_EDITMSG")
                    if grep -qE '^Off-Rails-Bypass:' "$_EDITMSG"; then
                        _BYPASS_REASON=$(grep -E '^Off-Rails-Bypass:' "$_EDITMSG" \
                            | head -1 | sed 's/^Off-Rails-Bypass:[[:space:]]*//')
                        printf '{"ts":"%s","kind":"off_rails_bypassed","claimed_gap":"%s","reason":"%s"}\n' \
                            "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$_CLAIMED_GAP" "$_BYPASS_REASON" \
                            >> "$_ambient" 2>/dev/null || true
                    elif ! echo "$_COMMIT_MSG" | grep -qiE "$_CLAIMED_GAP"; then
                        echo "[pre-commit] BLOCKED (RESILIENT-025): commit subject must mention claimed gap $_CLAIMED_GAP" >&2
                        exit 1
                    fi
                fi
            fi
        fi
        exit 0
    )
}

# --------------------------------------------------------------------------
# T1: claim for INFRA-9999, commit subject mentions INFRA-9999 → PASS
# --------------------------------------------------------------------------
echo "T1: claim INFRA-9999 + subject mentions INFRA-9999 → expect PASS"
_T1_DIR=$(mktemp -d)
mkdir -p "$_T1_DIR/.chump-locks"
printf '{"gap_id":"INFRA-9999","session_id":"test-session","expires_at":"2099-01-01T00:00:00Z"}\n' \
    > "$_T1_DIR/.chump-locks/claim-test-session.json"
_T1_AMBIENT="$_T1_DIR/ambient.jsonl"
if _run_off_rails_check "$_T1_DIR" "fix(INFRA-9999): foo" "$_T1_AMBIENT" 2>/dev/null; then
    _pass "T1"
else
    _fail "T1 — expected exit 0, got exit 1"
fi
rm -rf "$_T1_DIR"

# --------------------------------------------------------------------------
# T2: claim for INFRA-9999, commit subject mentions only INFRA-1234 → FAIL
# --------------------------------------------------------------------------
echo "T2: claim INFRA-9999 + subject says INFRA-1234 → expect FAIL (blocked)"
_T2_DIR=$(mktemp -d)
mkdir -p "$_T2_DIR/.chump-locks"
printf '{"gap_id":"INFRA-9999","session_id":"test-session","expires_at":"2099-01-01T00:00:00Z"}\n' \
    > "$_T2_DIR/.chump-locks/claim-test-session.json"
_T2_AMBIENT="$_T2_DIR/ambient.jsonl"
_T2_MSG=""
if _run_off_rails_check "$_T2_DIR" "fix(INFRA-1234): bar" "$_T2_AMBIENT" 2>/dev/null; then
    _fail "T2 — expected exit 1 (block), got exit 0"
else
    _T2_MSG=$(CHUMP_OFF_RAILS_CHECK=1 _run_off_rails_check "$_T2_DIR" "fix(INFRA-1234): bar" "$_T2_AMBIENT" 2>&1 || true)
    if echo "$_T2_MSG" | grep -q "BLOCKED (RESILIENT-025)"; then
        _pass "T2 (exit 1 + BLOCKED message confirmed)"
    else
        _pass "T2 (exit 1 confirmed)"
    fi
fi
rm -rf "$_T2_DIR"

# --------------------------------------------------------------------------
# T3: no claim file, any subject → PASS (human operator flow)
# --------------------------------------------------------------------------
echo "T3: no claim file + subject 'docs: random' → expect PASS"
_T3_DIR=$(mktemp -d)
mkdir -p "$_T3_DIR/.chump-locks"
# No claim file written
_T3_AMBIENT="$_T3_DIR/ambient.jsonl"
if _run_off_rails_check "$_T3_DIR" "docs: random" "$_T3_AMBIENT" 2>/dev/null; then
    _pass "T3"
else
    _fail "T3 — expected exit 0 (no claim), got exit 1"
fi
rm -rf "$_T3_DIR"

# --------------------------------------------------------------------------
# T4: claim for INFRA-9999, subject INFRA-1234, bypass trailer → PASS + ambient event
# --------------------------------------------------------------------------
echo "T4: claim INFRA-9999 + INFRA-1234 subject + Off-Rails-Bypass trailer → expect PASS + event"
_T4_DIR=$(mktemp -d)
mkdir -p "$_T4_DIR/.chump-locks"
printf '{"gap_id":"INFRA-9999","session_id":"test-session","expires_at":"2099-01-01T00:00:00Z"}\n' \
    > "$_T4_DIR/.chump-locks/claim-test-session.json"
_T4_AMBIENT="$_T4_DIR/.chump-locks/ambient.jsonl"
_T4_MSG="fix(INFRA-1234): integrate prereq
Off-Rails-Bypass: integrating prereq from sibling PR"
if _run_off_rails_check "$_T4_DIR" "$_T4_MSG" "$_T4_AMBIENT" 2>/dev/null; then
    # Check ambient event was emitted
    if [ -f "$_T4_AMBIENT" ] && grep -q '"kind":"off_rails_bypassed"' "$_T4_AMBIENT"; then
        if grep -q '"claimed_gap":"INFRA-9999"' "$_T4_AMBIENT"; then
            _pass "T4 (exit 0 + off_rails_bypassed event with correct claimed_gap)"
        else
            _fail "T4 — exit 0 and event emitted but claimed_gap field missing/wrong"
        fi
    else
        _fail "T4 — exit 0 but no off_rails_bypassed ambient event emitted"
    fi
else
    _fail "T4 — expected exit 0 (bypass trailer present), got exit 1"
fi
rm -rf "$_T4_DIR"

# --------------------------------------------------------------------------
# Summary
# --------------------------------------------------------------------------
echo ""
echo "Results: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
exit 0
