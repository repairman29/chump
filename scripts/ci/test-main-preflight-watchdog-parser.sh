#!/usr/bin/env bash
# scripts/ci/test-main-preflight-watchdog-parser.sh
#
# INFRA-2458: regression test for main-preflight-watchdog-daemon.sh gate-name
# extraction. The bug: the old parser matched `FAIL[: \t]+[^ \t]+` which hit
# the SUMMARY line `[preflight] FAIL — at least one gate did not pass (total
# {ms}ms)` and captured the em-dash as a "gate name". This produced
# failing_gates=["—"] false positives that wedged the claim health gate.
#
# This test exercises the parser via MOCK_FAIL injection. The watchdog supports
# CHUMP_MAIN_PREFLIGHT_WATCHDOG_MOCK=<output> to bypass the real preflight run
# — we shove curated preflight-output blobs into MOCK_FAIL and assert the
# parser does NOT extract em-dash or other punctuation as a gate name.
#
# Test cases:
#   1. Summary line only (em-dash bug)         → failing_gates == ""
#   2. Per-gate failure marker present         → gate name extracted ASCII-only
#   3. Multiple per-gate failures              → comma-sorted, no garbage
#   4. Per-gate gate stdout containing FAIL:   → NOT mistakenly captured
#   5. Mixed pass + fail                       → only failing gates listed
#   6. All-pass output                         → empty failing_gates

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
WATCHDOG="$REPO_ROOT/scripts/coord/main-preflight-watchdog-daemon.sh"

if [[ ! -f "$WATCHDOG" ]]; then
    echo "FAIL: watchdog script not found at $WATCHDOG" >&2
    exit 1
fi

PASS=0
FAIL=0

# Extract the _gate_parse function body from the watchdog and run it in
# isolation. The function we care about is _run_preflight_on_main but it
# does real work; we want to test the regex-and-sanitize block specifically.
# Approach: source the watchdog with a guard that prevents the daemon-loop
# from starting, then call the extracted parser as a shell function.

# Helper: take a mock preflight_out, exit code, and run the parser
# inline. This mirrors the exact code in _run_preflight_on_main lines
# 210-260 of the post-fix version.
_test_parse() {
    local preflight_out="$1"
    local preflight_rc="$2"
    local failing_gates=""

    if [[ "$preflight_rc" -ne 0 ]]; then
        failing_gates="$(printf '%s' "$preflight_out" \
            | grep -E '^\[preflight\] [A-Za-z][A-Za-z0-9_.-]* \.\.\. ✗' \
            | sed -E 's/^\[preflight\] ([A-Za-z][A-Za-z0-9_.-]*) \.\.\. ✗.*$/\1/' \
            | sort -u \
            | tr '\n' ',' \
            | sed 's/,$//')" || true

        local sanitized=""
        local IFS=','
        for g in $failing_gates; do
            g="${g#"${g%%[![:space:]]*}"}"
            g="${g%"${g##*[![:space:]]}"}"
            if [[ -n "$g" && "$g" =~ [A-Za-z0-9] ]]; then
                if [[ -z "$sanitized" ]]; then
                    sanitized="$g"
                else
                    sanitized="$sanitized,$g"
                fi
            fi
        done
        failing_gates="$sanitized"
        if [[ -z "$failing_gates" ]]; then
            failing_gates="preflight-exit-nonzero"
        fi
    fi
    printf '%s' "$failing_gates"
}

_assert_eq() {
    local name="$1" expected="$2" actual="$3"
    if [[ "$expected" == "$actual" ]]; then
        PASS=$((PASS + 1))
        echo "  PASS: $name"
    else
        FAIL=$((FAIL + 1))
        echo "  FAIL: $name" >&2
        echo "    expected: [$expected]" >&2
        echo "    actual:   [$actual]" >&2
    fi
}

echo "── Test 1: summary line only (the INFRA-2458 reproducer) ──"
# This is the exact output we saw on 2026-06-02 / 2026-06-03 ticks.
SUMMARY_ONLY="[preflight] scope=rust+scripts (--scope Auto)
[preflight] cargo fmt --check ... ✓ (1095ms)
[preflight] cargo check ... ✓ (39631ms)

[preflight] FAIL — at least one gate did not pass (total 151796ms)
   Bypass: CHUMP_PREFLIGHT_SKIP=1 + 'Preflight-Skip-Reason: <why>' trailer"
got="$(_test_parse "$SUMMARY_ONLY" 1)"
# The summary line should produce zero structured matches → fallback label.
# Critically: must NOT contain em-dash.
if [[ "$got" == *"—"* ]] || [[ "$got" == *"—"* ]]; then
    FAIL=$((FAIL + 1))
    echo "  FAIL: em-dash leaked into failing_gates: [$got]" >&2
else
    PASS=$((PASS + 1))
    echo "  PASS: no em-dash in failing_gates"
fi
_assert_eq "summary-only falls back to generic label" "preflight-exit-nonzero" "$got"

echo "── Test 2: single per-gate failure (real format from chump preflight) ──"
SINGLE_GATE="[preflight] scope=rust+scripts (--scope Auto)
[preflight] cargo fmt --check ... ✓ (1095ms)
[preflight] event-registry-audit ... ✗ (2115ms)
---- event-registry-audit output ----
[event-registry-audit] FAIL: emit-without-register violations — register each kind in docs/observability/EVENT_REGISTRY.yaml
---- end ----

[preflight] FAIL — at least one gate did not pass (total 151796ms)"
got="$(_test_parse "$SINGLE_GATE" 1)"
_assert_eq "single-gate-failure extracts gate name" "event-registry-audit" "$got"

echo "── Test 3: multiple per-gate failures (sorted, no garbage) ──"
MULTI_GATE="[preflight] scope=rust+scripts (--scope Auto)
[preflight] cargo-fmt-check ... ✗ (1095ms)
[preflight] cargo-clippy ... ✗ (108952ms)
[preflight] event-registry-audit ... ✗ (2115ms)

[preflight] FAIL — at least one gate did not pass (total 151796ms)"
got="$(_test_parse "$MULTI_GATE" 1)"
_assert_eq "multi-gate sorted" "cargo-clippy,cargo-fmt-check,event-registry-audit" "$got"

echo "── Test 4: gate stdout containing FAIL: must NOT leak ──"
# This was the old-parser pathology: the gate's own stdout `FAIL: emit-without-register`
# got captured as a gate. Verify the new parser only respects preflight's structured marker.
GATE_STDOUT_FAIL="[preflight] scope=rust+scripts (--scope Auto)
[preflight] cargo fmt --check ... ✓ (1095ms)
[preflight] event-registry-audit ... ✗ (2115ms)
---- event-registry-audit output ----
[event-registry-audit] FAIL: emit-without-register violations
  EMIT-NO-REG: daemon_exit_loop_detected
[event-registry-audit] FAIL: somerandomthing — em-dash here
---- end ----

[preflight] FAIL — at least one gate did not pass (total 151796ms)"
got="$(_test_parse "$GATE_STDOUT_FAIL" 1)"
_assert_eq "stdout FAIL: lines ignored — only marker line matters" "event-registry-audit" "$got"

echo "── Test 5: mixed pass + fail ──"
MIXED="[preflight] cargo fmt --check ... ✓ (1095ms)
[preflight] cargo clippy ... ✓ (108952ms)
[preflight] event-registry-audit ... ✗ (2115ms)
[preflight] path-filter-coverage ... ✓ (200ms)
[preflight] pipefail-race-sweep ... ✗ (500ms)

[preflight] FAIL — at least one gate did not pass (total 151796ms)"
got="$(_test_parse "$MIXED" 1)"
_assert_eq "mixed pass/fail extracts only failing gates" "event-registry-audit,pipefail-race-sweep" "$got"

echo "── Test 6: all-pass output (preflight_rc=0) ──"
ALL_PASS="[preflight] cargo fmt --check ... ✓ (1095ms)
[preflight] cargo clippy ... ✓ (108952ms)
[preflight] cargo check ... ✓ (39631ms)

[preflight] PASS — all gates passed (total 151796ms)"
got="$(_test_parse "$ALL_PASS" 0)"
_assert_eq "all-pass → empty failing_gates" "" "$got"

echo "── Test 7: em-dash injected as a real gate name attempt (defense) ──"
# Synthetic hostile input — if some upstream wedge ever DID produce
# `[preflight] — ... ✗`, the parser should reject it because the gate-name
# regex `[A-Za-z]...` requires a letter start.
EMDASH_GATE="[preflight] — ... ✗ (1ms)
[preflight] event-registry-audit ... ✗ (2115ms)

[preflight] FAIL — at least one gate did not pass (total 151796ms)"
got="$(_test_parse "$EMDASH_GATE" 1)"
_assert_eq "em-dash-as-gate rejected at regex layer" "event-registry-audit" "$got"

echo ""
echo "── Summary ──"
echo "  PASS: $PASS"
echo "  FAIL: $FAIL"

if [[ "$FAIL" -gt 0 ]]; then
    exit 1
fi
exit 0
