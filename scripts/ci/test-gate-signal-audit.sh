#!/usr/bin/env bash
# test-gate-signal-audit.sh — CREDIBLE-271 (SHIP-INFRA 4/7 [RELIABILITY])
#
# Regression guard for scripts/coord/gate-signal-audit.sh. Builds a synthetic
# ambient.jsonl fixture with known-phantom reapers, a known-signal reaper, and
# a mix of farmer_auth_dead events (some with nearby shipping activity, one
# without), then asserts the audit script classifies each correctly. Also
# asserts the write-only grace-guard check flags the known real instance
# (required-check-monitor.sh's --pr consult path has 0 external callers as of
# this writing — see script comment).
#
# Runs entirely offline (no gh, no network) against a tempdir fixture, so it
# is safe to run in CI.

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
AUDIT="$REPO_ROOT/scripts/coord/gate-signal-audit.sh"

FAIL=0
assert_contains() {
    local haystack="$1" needle="$2" desc="$3"
    if [[ "$haystack" == *"$needle"* ]]; then
        echo "[test] PASS: $desc"
    else
        echo "[test] FAIL: $desc — expected to find: $needle"
        FAIL=1
    fi
}

[[ -x "$AUDIT" ]] || { echo "[test] FAIL: gate-signal-audit.sh not executable"; exit 1; }
[[ "$(bash -n "$AUDIT" 2>&1)" == "" ]] || { echo "[test] FAIL: syntax error in gate-signal-audit.sh"; bash -n "$AUDIT"; exit 1; }

WORK="$(mktemp -d /tmp/gate-signal-audit-test-XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

AMBIENT="$WORK/ambient.jsonl"
OUT="$WORK/report.md"

cat > "$AMBIENT" <<'JSONL'
{"ts":"2026-08-01T00:00:00Z","kind":"sccache_reaped","bytes_freed":0,"freed_kb":0}
{"ts":"2026-08-01T06:00:00Z","kind":"sccache_reaped","bytes_freed":0,"freed_kb":0}
{"ts":"2026-08-01T12:00:00Z","kind":"sccache_reaped","bytes_freed":0,"freed_kb":0}
{"ts":"2026-08-01T00:00:00Z","kind":"target_artifact_reaped","freed_gb":0.00}
{"ts":"2026-08-02T00:00:00Z","kind":"target_artifact_reaped","freed_gb":0.00}
{"ts":"2026-08-01T00:00:00Z","kind":"incremental_reaped","bytes_freed":500000000,"freed_kb":488281}
{"ts":"2026-08-02T00:00:00Z","kind":"incremental_reaped","bytes_freed":300000000,"freed_kb":292968}
{"ts":"2026-08-01T03:00:00Z","kind":"farmer_auth_dead","reason":"token_age_s"}
{"ts":"2026-08-01T03:10:00Z","kind":"gap_shipped","gap_id":"TEST-1"}
{"ts":"2026-08-01T09:00:00Z","kind":"farmer_auth_dead","reason":"token_age_s"}
{"ts":"2026-08-01T09:05:00Z","kind":"pr_merged","pr":42}
{"ts":"2026-08-03T15:00:00Z","kind":"farmer_auth_dead","reason":"validity_probe_broken"}
JSONL

"$AUDIT" --ambient-file "$AMBIENT" --output "$OUT" --min-runs 2 --fp-window-mins 30 --skip-required-checks > "$WORK/stdout.log" 2>&1
STATUS=$?
if [[ $STATUS -ne 0 ]]; then
    echo "[test] FAIL: gate-signal-audit.sh exited non-zero ($STATUS)"
    cat "$WORK/stdout.log"
    exit 1
fi

[[ -f "$OUT" ]] || { echo "[test] FAIL: report file not written"; exit 1; }
REPORT="$(cat "$OUT")"

# Category 1: phantom reapers.
assert_contains "$REPORT" "sccache_reaped | 3 | 0 | PHANTOM" "sccache_reaped (3 runs, 0 bytes) flagged PHANTOM"
assert_contains "$REPORT" "target_artifact_reaped | 2 | 0 | PHANTOM" "target_artifact_reaped (2 runs, 0 bytes) flagged PHANTOM"
assert_contains "$REPORT" "incremental_reaped | 2 | 800000000 | signal" "incremental_reaped (real bytes freed) NOT flagged phantom"
assert_contains "$REPORT" "Reaper phantom rate: **66.7%**" "reaper phantom rate computed as 2/3"

# Category 2: farmer_auth_dead FP rate — 2 of 3 events have shipping activity
# within the 30-minute window, 1 does not.
assert_contains "$REPORT" "Events: 3, classified FP: 2" "farmer_auth_dead FP count is 2/3"
assert_contains "$REPORT" "farmer_auth_dead FP rate: **66.7%**" "farmer_auth_dead FP rate computed as 66.7%"

# Category 3: write-only grace-guard — required-check-monitor.sh's --pr
# consult path has 0 external callers in this repo today.
assert_contains "$REPORT" "required-check-monitor.sh | 0 | WRITE_ONLY" "required-check-monitor.sh flagged WRITE_ONLY (0 external callers)"

# Negative check: prove the classification is not a rubber stamp — a reaper
# fixture with only 1 zero-byte run (< min-runs) must NOT be flagged phantom.
cat >> "$AMBIENT" <<'JSONL'
{"ts":"2026-08-04T00:00:00Z","kind":"branch_reaped_solo_test","bytes_freed":0}
JSONL
"$AUDIT" --ambient-file "$AMBIENT" --output "$OUT" --min-runs 2 --fp-window-mins 30 --skip-required-checks > /dev/null 2>&1
REPORT2="$(cat "$OUT")"
assert_contains "$REPORT2" "branch_reaped_solo_test | 1 | 0 | signal" "single zero-byte run (below min-runs) NOT flagged phantom"

if [[ "$FAIL" -eq 0 ]]; then
    echo "[test] all gate-signal-audit assertions passed"
    exit 0
else
    echo "[test] one or more assertions FAILED"
    exit 1
fi
