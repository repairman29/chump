#!/usr/bin/env bash
# INFRA-079: tests for the cross-judge audit guard.
# Exercises the python checker (scripts/ci/check-cross-judge.py)
# directly. Run from repo root: bash scripts/ci/test-cross-judge-guard.sh

set -e
REPO_ROOT=$(git rev-parse --show-toplevel)
cd "$REPO_ROOT"

CHECKER="$REPO_ROOT/scripts/ci/check-cross-judge.py"
[ -x "$CHECKER" ] || { echo "[FATAL] checker not executable: $CHECKER" >&2; exit 2; }

PASS=0
FAIL=0
TMPDIR_TEST=$(mktemp -d)
trap 'rm -rf "$TMPDIR_TEST"' EXIT

pass() { echo "[PASS] $1"; PASS=$((PASS+1)); }
fail() { echo "[FAIL] $1"; FAIL=$((FAIL+1)); }

run_checker() {
    # $1 gid, $2 gap-block-content, $3 prereg-content (or empty), $4 repo-root
    local gid="$1" block="$2" prereg="$3" root="${4:-$TMPDIR_TEST}"
    local block_file="$TMPDIR_TEST/gap-block.yaml"
    printf '%s' "$block" > "$block_file"
    local args=("$gid" "--gap-block" "$block_file" "--repo-root" "$root")
    if [ -n "$prereg" ]; then
        local prereg_file="$TMPDIR_TEST/prereg.md"
        printf '%s' "$prereg" > "$prereg_file"
        args+=("--prereg" "$prereg_file")
    fi
    if [ "${TEST_VERBOSE:-0}" = "1" ]; then
        python3 "$CHECKER" "${args[@]}"
    else
        python3 "$CHECKER" "${args[@]}" 2>/dev/null
    fi
}

# ── case 1: bare closure with no audit / waiver / prereg → fail ──────────────
BLOCK_BARE='- id: EVAL-TEST
  domain: EVAL
  status: done
'
if run_checker EVAL-TEST "$BLOCK_BARE" ""; then
    fail "bare closure unexpectedly passed"
else
    pass "bare closure fails"
fi

# ── case 2: single_judge_waived: true + reason ≥ 20 chars → pass ─────────────
BLOCK_WAIVED='- id: EVAL-TEST
  domain: EVAL
  status: done
  single_judge_waived: true
  single_judge_waiver_reason: harness preflight only — no judge labels collected
'
if run_checker EVAL-TEST "$BLOCK_WAIVED" ""; then
    pass "single_judge_waived + ≥20 char reason passes"
else
    fail "single_judge_waived + reason unexpectedly failed"
fi

# ── case 3: waiver flag without reason → fail ────────────────────────────────
BLOCK_WAIVED_NOREASON='- id: EVAL-TEST
  status: done
  single_judge_waived: true
'
if run_checker EVAL-TEST "$BLOCK_WAIVED_NOREASON" ""; then
    fail "waiver without reason unexpectedly passed"
else
    pass "waiver without reason fails"
fi

# ── case 4: waiver with too-short reason → fail ──────────────────────────────
BLOCK_WAIVED_SHORTREASON='- id: EVAL-TEST
  status: done
  single_judge_waived: true
  single_judge_waiver_reason: short
'
if run_checker EVAL-TEST "$BLOCK_WAIVED_SHORTREASON" ""; then
    fail "waiver with short reason unexpectedly passed"
else
    pass "waiver with short reason fails"
fi

# ── case 5: cross_judge_audit pointing at a JSONL with 2 families → pass ─────
mkdir -p "$TMPDIR_TEST/logs/ab"
AUDIT_FILE="$TMPDIR_TEST/logs/ab/eval-test-audit.jsonl"
cat > "$AUDIT_FILE" <<'EOF'
{"trial_id": 1, "judge_model": "claude-3-5-sonnet", "verdict": "pass"}
{"trial_id": 1, "judge_model": "gpt-4o", "verdict": "pass"}
{"trial_id": 2, "judge_model": "claude-3-5-sonnet", "verdict": "fail"}
{"trial_id": 2, "judge_model": "gpt-4o", "verdict": "fail"}
EOF
BLOCK_AUDIT='- id: EVAL-TEST
  status: done
  cross_judge_audit: logs/ab/eval-test-audit.jsonl
'
if run_checker EVAL-TEST "$BLOCK_AUDIT" "" "$TMPDIR_TEST"; then
    pass "cross_judge_audit with 2 families passes"
else
    fail "cross_judge_audit with 2 families unexpectedly failed"
fi

# ── case 6: cross_judge_audit but only 1 family → fail ───────────────────────
SINGLEFAM_FILE="$TMPDIR_TEST/logs/ab/eval-test-singlefam.jsonl"
cat > "$SINGLEFAM_FILE" <<'EOF'
{"trial_id": 1, "judge_model": "llama-3.3-70b", "verdict": "pass"}
{"trial_id": 2, "judge_model": "llama-3.3-70b", "verdict": "fail"}
EOF
BLOCK_AUDIT_1FAM='- id: EVAL-TEST
  status: done
  cross_judge_audit: logs/ab/eval-test-singlefam.jsonl
'
if run_checker EVAL-TEST "$BLOCK_AUDIT_1FAM" "" "$TMPDIR_TEST"; then
    fail "single-family audit unexpectedly passed"
else
    pass "single-family audit fails"
fi

# ── case 7: cross_judge_audit with missing path → fail ───────────────────────
BLOCK_AUDIT_MISSING='- id: EVAL-TEST
  status: done
  cross_judge_audit: logs/ab/does-not-exist.jsonl
'
if run_checker EVAL-TEST "$BLOCK_AUDIT_MISSING" "" "$TMPDIR_TEST"; then
    fail "missing audit path unexpectedly passed"
else
    pass "missing audit path fails"
fi

# ── case 8: prereg declares single-judge scope → pass ────────────────────────
BLOCK_NO_AUDIT='- id: EVAL-TEST
  status: done
'
PREREG_SINGLE_SCOPE='# Preregistration — EVAL-TEST

This is a deliberately single-judge run intended only to verify the
harness round-trip. Single judge scope is acceptable here because no
mechanism claims will be produced from the output.

## Methodology
single judge design — flagged per docs/RESEARCH_INTEGRITY.md.
'
if run_checker EVAL-TEST "$BLOCK_NO_AUDIT" "$PREREG_SINGLE_SCOPE"; then
    pass "prereg with single-judge scope passes"
else
    fail "prereg with single-judge scope unexpectedly failed"
fi

# ── case 9: prereg without scope attestation → fail ──────────────────────────
PREREG_NORMAL='# Preregistration — EVAL-TEST
Multi-judge design with claude + gpt-4o.
'
if run_checker EVAL-TEST "$BLOCK_NO_AUDIT" "$PREREG_NORMAL"; then
    fail "prereg without scope attestation unexpectedly passed"
else
    pass "prereg without scope attestation fails"
fi

# ── summary ──────────────────────────────────────────────────────────────────
echo ""
echo "Passed: $PASS  Failed: $FAIL"
[ "$FAIL" -eq 0 ]
