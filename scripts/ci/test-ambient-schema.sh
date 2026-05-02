#!/usr/bin/env bash
# INFRA-101: regression test for the ambient-emit schema validator.
# Covers each well-known event kind (session_start, session_end, file_edit,
# commit, bash_call, INTENT, ALERT) plus violation cases (missing required
# field, bad event kind, malformed timestamp, etc.).
#
# Run from repo root: bash scripts/ci/test-ambient-schema.sh

set -e
REPO_ROOT=$(git rev-parse --show-toplevel)
cd "$REPO_ROOT"

PASS=0
FAIL=0
SANDBOX=$(mktemp -d)
trap 'rm -rf "$SANDBOX"' EXIT

pass() { echo "[PASS] $1"; PASS=$((PASS+1)); }
fail() { echo "[FAIL] $1"; FAIL=$((FAIL+1)); }

# Each test runs the emit script with a controlled CHUMP_AMBIENT_LOG so we
# don't spam the real ambient.jsonl. The validator should accept the valid
# cases (exit 0, line written) and reject the invalid cases (exit 1, no
# line written).

EMIT="$REPO_ROOT/scripts/dev/ambient-emit.sh"
LOG="$SANDBOX/ambient.jsonl"

run_emit() {
    # $1 = expected exit (0 or 1)
    # $2 = test description
    # $3+ = args to ambient-emit.sh
    local expected="$1"; shift
    local desc="$1"; shift
    : > "$LOG"
    local out actual=0
    # Capture real exit without `|| true` (which would mask it as 0) by
    # using `|| actual=$?` — the right side only runs on failure.
    out=$(CHUMP_AMBIENT_LOG="$LOG" "$EMIT" "$@" 2>&1) || actual=$?
    if [[ "$actual" -ne "$expected" ]]; then
        fail "$desc — expected exit $expected, got $actual"
        printf '  output: %s\n' "$out"
        return
    fi
    if [[ "$expected" -eq 0 ]] && [[ ! -s "$LOG" ]]; then
        fail "$desc — expected line written, log is empty"
        return
    fi
    if [[ "$expected" -eq 1 ]] && [[ -s "$LOG" ]]; then
        fail "$desc — expected reject, but line was written: $(cat "$LOG")"
        return
    fi
    pass "$desc"
}

# ── Valid cases (one per event kind) ───────────────────────────────────────
# Each well-known event kind, with all required fields populated, should
# emit a clean line and exit 0.

run_emit 0 "session_start (no extra fields)" session_start
run_emit 0 "session_end (no extra fields)" session_end
run_emit 0 "file_edit with path" file_edit "path=/some/file.rs"
run_emit 0 "commit with sha+msg" commit "sha=abc1234" "msg=feat: x"
run_emit 0 "commit with sha+msg+gap" commit "sha=abc1234" "msg=feat: x" "gap=INFRA-101"
run_emit 0 "bash_call with cmd" bash_call "cmd=echo hello"
run_emit 0 "INTENT with gap" INTENT "gap=INFRA-101"
run_emit 0 "INTENT with gap+files" INTENT "gap=INFRA-101" "files=src/foo.rs"
run_emit 0 "ALERT with kind" ALERT "kind=lease_overlap"
run_emit 0 "ALERT with kind+note" ALERT "kind=pr_stuck" "note=#999 BLOCKED"

# ── Violation cases ────────────────────────────────────────────────────────

run_emit 1 "file_edit missing required path" file_edit
run_emit 1 "commit missing required msg" commit "sha=abc1234"
run_emit 1 "commit missing required sha" commit "msg=just a message"
run_emit 1 "bash_call missing required cmd" bash_call
run_emit 1 "INTENT missing required gap" INTENT
run_emit 1 "ALERT missing required kind" ALERT
run_emit 1 "unknown event kind not in enum" not_a_real_event

# ── Bypass works ───────────────────────────────────────────────────────────

: > "$LOG"
out=$(CHUMP_AMBIENT_LOG="$LOG" CHUMP_AMBIENT_SCHEMA_CHECK=0 \
    "$EMIT" not_a_real_event "extra=foo" 2>&1) || true
if [[ -s "$LOG" ]]; then
    pass "CHUMP_AMBIENT_SCHEMA_CHECK=0 bypass writes the line"
else
    fail "CHUMP_AMBIENT_SCHEMA_CHECK=0 bypass should have written the line"
    printf '  output: %s\n' "$out"
fi

# ── Schema integrity sanity check ──────────────────────────────────────────

if python3 -c "import json; json.load(open('$REPO_ROOT/docs/ambient-schema.json'))" 2>/dev/null; then
    pass "docs/ambient-schema.json parses as valid JSON"
else
    fail "docs/ambient-schema.json is not valid JSON"
fi

echo ""
echo "Passed: $PASS  Failed: $FAIL"
[ "$FAIL" -eq 0 ]
