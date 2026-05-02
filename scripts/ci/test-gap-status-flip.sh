#!/usr/bin/env bash
# INFRA-158: regression test for the gap-status-check workflow guard
# (INFRA-066). The script scripts/coord/check-gap-status-flip.sh is
# called by .github/workflows/gap-status-guard.yml on every PR. It
# rejects PRs whose title is "<DOMAIN>-<NUMBER>: ..." but whose
# gaps.yaml entry for that gap is still status: open. QUALITY-005
# audit (2026-04-25) found 7 of 31 "open" gaps had already shipped
# without the YAML flip; this guard closes that loop. PR #639 (this
# session, 2026-04-30) is the most-recent example of the guard
# catching real drift.
#
# Run from repo root: bash scripts/ci/test-gap-status-flip.sh

set -e
REPO_ROOT=$(git rev-parse --show-toplevel)
cd "$REPO_ROOT"

CHECKER="$REPO_ROOT/scripts/coord/check-gap-status-flip.sh"
[ -x "$CHECKER" ] || { echo "[FATAL] checker not executable: $CHECKER" >&2; exit 2; }

PASS=0
FAIL=0
TMPDIR_TEST=$(mktemp -d)
trap 'rm -rf "$TMPDIR_TEST"' EXIT

pass() { echo "[PASS] $1"; PASS=$((PASS+1)); }
fail() { echo "[FAIL] $1"; FAIL=$((FAIL+1)); }

# Helper: run checker against a synthetic gaps.yaml + PR title.
run_checker() {
    local title="$1" yaml_content="$2"
    local yaml_file="$TMPDIR_TEST/gaps.yaml"
    printf '%s' "$yaml_content" > "$yaml_file"
    if [ "${TEST_VERBOSE:-0}" = "1" ]; then
        bash "$CHECKER" "$title" "$yaml_file"
    else
        bash "$CHECKER" "$title" "$yaml_file" >/dev/null 2>&1
    fi
}

# Reusable YAML fragments
YAML_DONE='gaps:
- id: INFRA-001
  status: done
  closed_pr: 100
'
YAML_OPEN='gaps:
- id: INFRA-001
  status: open
'

# ── case 1: title without gap-id prefix → guard skips (exit 0) ───────────────
if run_checker "chore(release): bump v0.1.2" "$YAML_OPEN"; then
    pass "title without DOMAIN-N: prefix skipped (exit 0)"
else
    fail "non-prefixed title incorrectly rejected"
fi

# ── case 2: title implies close + gap is done in YAML → guard PASSES ─────────
if run_checker "INFRA-001: implement the thing" "$YAML_DONE"; then
    pass "<ID>: title + status=done in YAML passes"
else
    fail "title-implies-close + gap-done was rejected"
fi

# ── case 3: title implies close + gap STILL open in YAML → guard FAILS ───────
if run_checker "INFRA-001: implement the thing" "$YAML_OPEN"; then
    fail "title-implies-close + gap=open unexpectedly passed (this is the bug the guard exists to catch)"
else
    pass "title-implies-close + gap=open blocked (the QUALITY-005 case)"
fi

# ── case 4: title implies close + gap MISSING from YAML → guard PASSES ───────
# The script explicitly accepts this case as a "new gap filed by this PR."
YAML_NO_INFRA001='gaps:
- id: INFRA-002
  status: open
'
if run_checker "INFRA-001: file new gap" "$YAML_NO_INFRA001"; then
    pass "title implies close + gap not in YAML accepted (assumed new filing)"
else
    fail "missing-gap case incorrectly rejected"
fi

# ── case 5: empty title → guard skips (exit 0, with notice) ──────────────────
if run_checker "" "$YAML_OPEN"; then
    pass "empty title skipped (exit 0)"
else
    fail "empty title incorrectly rejected"
fi

# ── case 6: 'chore(close):' style title → guard skips (no DOMAIN-N: prefix) ──
# This is the prefix used by bot-merge.sh's auto-close commits + manual
# closure PRs. Title pattern: "chore(close): auto-close INFRA-001 via PR #N"
if run_checker "chore(close): auto-close INFRA-001 via PR #639 (INFRA-154)" "$YAML_OPEN"; then
    pass "chore(close): prefix skipped (no DOMAIN-N: at start of title)"
else
    fail "chore(close): title incorrectly rejected"
fi

echo ""
echo "Passed: $PASS  Failed: $FAIL"
[ "$FAIL" -eq 0 ]
