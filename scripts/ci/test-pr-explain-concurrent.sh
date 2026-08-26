#!/usr/bin/env bash
# test-pr-explain-concurrent.sh — INFRA-1497
#
# Source-level assertions that the 3 gh callsites in the pr-explain handlers
# (handle_pr_diff, handle_pr_ac_fit) use tokio::process::Command instead of
# blocking std::process::Command. This is what guarantees /api/health stays
# responsive (<500ms p95) under concurrent pr-explain load: a blocking
# std::process::Command call ties up a tokio worker thread for the full gh
# subprocess lifetime, which is exactly the class of failure INFRA-1485
# fixed for handle_pr_detail. No running server required — mirrors the
# INFRA-1466 test-api-health-pillars-timeout.sh pattern.
#
# Run: bash scripts/ci/test-pr-explain-concurrent.sh
# Exit 0 = pass.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WEB_SERVER="$REPO_ROOT/src/web_server.rs"

PASS=0; FAIL=0
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

echo "=== INFRA-1497 pr-explain gh-callsite async assertions ==="
echo

# Isolate the handle_pr_diff and handle_pr_ac_fit handler bodies.
extract_fn() {
    awk "/^async fn $1\(/{flag=1} flag{print} flag && /^}/{exit}" "$WEB_SERVER"
}

DIFF_BODY="$(extract_fn handle_pr_diff)"
AC_FIT_BODY="$(extract_fn handle_pr_ac_fit)"

if [[ -z "$DIFF_BODY" ]]; then
    fail "could not locate handle_pr_diff in web_server.rs"
else
    ok "located handle_pr_diff"
fi
if [[ -z "$AC_FIT_BODY" ]]; then
    fail "could not locate handle_pr_ac_fit in web_server.rs"
else
    ok "located handle_pr_ac_fit"
fi

# AC1: no blocking std::process::Command remains in either handler.
if echo "$DIFF_BODY" | grep -q "std::process::Command"; then
    fail "handle_pr_diff still uses blocking std::process::Command"
else
    ok "handle_pr_diff has no blocking std::process::Command"
fi
if echo "$AC_FIT_BODY" | grep -q "std::process::Command"; then
    fail "handle_pr_ac_fit still uses blocking std::process::Command"
else
    ok "handle_pr_ac_fit has no blocking std::process::Command"
fi

# AC2: all 3 gh callsites now use tokio::process::Command with .await.
DIFF_GH_COUNT="$(echo "$DIFF_BODY" | grep -c 'tokio::process::Command::new("gh")' || true)"
AC_FIT_GH_COUNT="$(echo "$AC_FIT_BODY" | grep -c 'tokio::process::Command::new("gh")' || true)"

if [[ "$DIFF_GH_COUNT" -ge 1 ]]; then
    ok "handle_pr_diff uses tokio::process::Command for gh ($DIFF_GH_COUNT callsite)"
else
    fail "handle_pr_diff missing tokio::process::Command gh callsite"
fi
if [[ "$AC_FIT_GH_COUNT" -ge 2 ]]; then
    ok "handle_pr_ac_fit uses tokio::process::Command for gh ($AC_FIT_GH_COUNT callsites)"
else
    fail "handle_pr_ac_fit expected 2 tokio gh callsites, found $AC_FIT_GH_COUNT"
fi

# AC3: each tokio gh call is followed by .await before the next statement
# (i.e. .output() is awaited, not fired-and-forgotten).
TOTAL_GH_CALLS="$(( DIFF_GH_COUNT + AC_FIT_GH_COUNT ))"
TOTAL_OUTPUT_AWAIT="$(printf '%s\n%s\n' "$DIFF_BODY" "$AC_FIT_BODY" | grep -c '\.output()' || true)"
if [[ "$TOTAL_OUTPUT_AWAIT" -ge "$TOTAL_GH_CALLS" ]]; then
    ok ".output() present for every tokio gh callsite ($TOTAL_OUTPUT_AWAIT)"
else
    fail ".output() count ($TOTAL_OUTPUT_AWAIT) below gh callsite count ($TOTAL_GH_CALLS)"
fi
AWAIT_AFTER_OUTPUT="$(printf '%s\n%s\n' "$DIFF_BODY" "$AC_FIT_BODY" | grep -c '\.output()$\|\.output()\s*$' || true)"
# .output() followed on the next line by .await — check the raw source for the pair.
if grep -A1 '\.output()$' "$WEB_SERVER" | grep -q '\.await'; then
    ok ".output() is awaited (async, non-blocking)"
else
    fail ".output() does not appear to be awaited anywhere in web_server.rs"
fi

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
