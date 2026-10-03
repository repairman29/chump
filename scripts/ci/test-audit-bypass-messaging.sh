#!/usr/bin/env bash
# test-audit-bypass-messaging.sh — INFRA-4537 smoke test.
#
# Exercises scripts/ci/audit-bypass-messaging.sh against a stubbed `gh` CLI
# so the test stays network-free. Verifies:
#   1. No failed jobs -> PASS (rc=0).
#   2. One failed job whose log has "How to bypass cleanly:" -> PASS (rc=0).
#   3. One failed job whose log is missing the line -> FAIL (rc=1).
#   4. Mixed: one failed job with the line, one without -> FAIL (rc=1), and
#      the passing job is still reported OK.
#   5. `gh run view --json jobs` failure -> invocation error (rc=2).

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/ci/audit-bypass-messaging.sh"

[[ -x "$SCRIPT" ]] || { echo "FAIL: $SCRIPT not executable"; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$TMP/bin"
export PATH="$TMP/bin:$PATH"

write_gh_stub() {
    # $1 = jobs JSON body, $2 = assoc-array-ish "jobid:logbody" pairs file
    cat > "$TMP/bin/gh" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
STUB_DIR="$(dirname "$0")/../stub-data"
if [[ "$1 $2" == "run view" ]]; then
    shift 2
    run_id="$1"; shift
    job_id=""
    want_log=0
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --json) shift 2 ;;
            --job) job_id="$2"; shift 2 ;;
            --log) want_log=1; shift ;;
            --repo) shift 2 ;;
            *) shift ;;
        esac
    done
    if [[ "$want_log" -eq 1 ]]; then
        cat "$STUB_DIR/log-${job_id}.txt" 2>/dev/null || { echo "no log" >&2; exit 1; }
    else
        cat "$STUB_DIR/jobs.json"
    fi
else
    echo "unsupported stub invocation: $*" >&2
    exit 1
fi
STUB
    chmod +x "$TMP/bin/gh"
}
write_gh_stub
mkdir -p "$TMP/stub-data"

# ── Test 1: no failed jobs -> PASS ───────────────────────────────────────────
echo "Test 1: no failed jobs -> PASS"
cat > "$TMP/stub-data/jobs.json" <<'EOF'
{"jobs":[{"databaseId":1,"name":"fast-checks","conclusion":"success"},{"databaseId":2,"name":"clippy","conclusion":"success"}]}
EOF
out=$("$SCRIPT" --run-id 100 2>&1) && rc=0 || rc=$?
if [[ "$rc" -eq 0 && "$out" == *"nothing to audit"* ]]; then
    echo "  PASS"
else
    echo "  FAIL: expected rc=0 + 'nothing to audit', got rc=$rc: $out"
    exit 1
fi

# ── Test 2: one failed job, has bypass line -> PASS ──────────────────────────
echo "Test 2: failed job with bypass line -> PASS"
cat > "$TMP/stub-data/jobs.json" <<'EOF'
{"jobs":[{"databaseId":1,"name":"fast-checks","conclusion":"failure"}]}
EOF
printf 'some log line\nHow to bypass cleanly: set FOO=1\nmore log\n' > "$TMP/stub-data/log-1.txt"
out=$("$SCRIPT" --run-id 100 2>&1) && rc=0 || rc=$?
if [[ "$rc" -eq 0 && "$out" == *"OK: 'fast-checks'"* ]]; then
    echo "  PASS"
else
    echo "  FAIL: expected rc=0 + OK line, got rc=$rc: $out"
    exit 1
fi

# ── Test 3: one failed job, missing bypass line -> FAIL ──────────────────────
echo "Test 3: failed job missing bypass line -> FAIL"
printf 'some log line\nno bypass info here\n' > "$TMP/stub-data/log-1.txt"
out=$("$SCRIPT" --run-id 100 2>&1) && rc=0 || rc=$?
if [[ "$rc" -eq 1 && "$out" == *"FAIL: 'fast-checks'"* ]]; then
    echo "  PASS"
else
    echo "  FAIL: expected rc=1 + FAIL line, got rc=$rc: $out"
    exit 1
fi

# ── Test 4: mixed -> FAIL, one OK one FAIL reported ──────────────────────────
echo "Test 4: mixed failed jobs -> FAIL, per-job reporting"
cat > "$TMP/stub-data/jobs.json" <<'EOF'
{"jobs":[{"databaseId":1,"name":"fast-checks","conclusion":"failure"},{"databaseId":2,"name":"clippy","conclusion":"failure"},{"databaseId":3,"name":"cargo-test","conclusion":"success"}]}
EOF
printf 'How to bypass cleanly: use --skip\n' > "$TMP/stub-data/log-1.txt"
printf 'no bypass line at all\n' > "$TMP/stub-data/log-2.txt"
out=$("$SCRIPT" --run-id 100 2>&1) && rc=0 || rc=$?
if [[ "$rc" -eq 1 && "$out" == *"OK: 'fast-checks'"* && "$out" == *"FAIL: 'clippy'"* ]]; then
    echo "  PASS"
else
    echo "  FAIL: expected rc=1 with fast-checks OK + clippy FAIL, got rc=$rc: $out"
    exit 1
fi

# ── Test 5: gh run view --json jobs errors -> invocation error rc=2 ──────────
echo "Test 5: gh lookup failure -> rc=2"
cat > "$TMP/bin/gh" <<'STUB'
#!/usr/bin/env bash
echo "API rate limited" >&2
exit 1
STUB
chmod +x "$TMP/bin/gh"
out=$("$SCRIPT" --run-id 100 2>&1) && rc=0 || rc=$?
if [[ "$rc" -eq 2 ]]; then
    echo "  PASS"
else
    echo "  FAIL: expected rc=2, got rc=$rc: $out"
    exit 1
fi

echo
echo "All 5 audit-bypass-messaging smoke tests passed."
