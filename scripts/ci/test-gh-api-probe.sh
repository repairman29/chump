#!/usr/bin/env bash
# scripts/ci/test-gh-api-probe.sh — INFRA-539 / CREDIBLE-032
#
# Smoke test: verifies the GitHub-unreachable probe is wired into both
# bot-merge.sh and run-fleet.sh, with CREDIBLE-032 failure-class taxonomy.

set -euo pipefail

PASS=0; FAIL=0
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
BM="$REPO_ROOT/scripts/coord/bot-merge.sh"
RF="$REPO_ROOT/scripts/dispatch/run-fleet.sh"

echo "=== INFRA-539 gh-api-probe smoke test ==="
echo

# 1. gh_api_probe function exists in bot-merge.sh
if grep -q 'gh_api_probe()' "$BM"; then
    ok "gh_api_probe() defined in bot-merge.sh"
else
    fail "gh_api_probe() missing from bot-merge.sh"
fi

# 2. bot-merge.sh calls gh_api_probe (appears >=2 times: definition + call)
_bm_count=$(grep -c 'gh_api_probe' "$BM" 2>/dev/null || echo 0)
if [[ "$_bm_count" -ge 2 ]]; then
    ok "gh_api_probe called in bot-merge.sh"
else
    fail "gh_api_probe not called in bot-merge.sh (only ${_bm_count} occurrence)"
fi

# 3. bot-merge.sh emits kind=github_unreachable
if grep -q 'github_unreachable' "$BM"; then
    ok "bot-merge.sh emits kind=github_unreachable"
else
    fail "bot-merge.sh missing github_unreachable emit"
fi

# 4. bot-merge.sh respects CHUMP_GH_PROBE_SKIP bypass
if grep -q 'CHUMP_GH_PROBE_SKIP' "$BM"; then
    ok "bot-merge.sh respects CHUMP_GH_PROBE_SKIP bypass"
else
    fail "bot-merge.sh missing CHUMP_GH_PROBE_SKIP bypass"
fi

# 5. run-fleet.sh contains the probe
if grep -q 'github_unreachable' "$RF"; then
    ok "run-fleet.sh emits kind=github_unreachable"
else
    fail "run-fleet.sh missing github_unreachable emit"
fi

# 6. run-fleet.sh respects CHUMP_GH_PROBE_SKIP bypass
if grep -q 'CHUMP_GH_PROBE_SKIP' "$RF"; then
    ok "run-fleet.sh respects CHUMP_GH_PROBE_SKIP bypass"
else
    fail "run-fleet.sh missing CHUMP_GH_PROBE_SKIP bypass"
fi

# 7. run-fleet.sh probe is after teardown path so FLEET_SIZE=0 still works when GitHub is down
_teardown_line=$(grep -n '"\$FLEET_SIZE" = "0"' "$RF" 2>/dev/null | head -1 | cut -d: -f1 || true)
_probe_line=$(grep -n 'INFRA-539' "$RF" 2>/dev/null | head -1 | cut -d: -f1 || true)
if [[ -n "$_teardown_line" && -n "$_probe_line" && "$_probe_line" -gt "$_teardown_line" ]]; then
    ok "run-fleet.sh probe is after teardown path (probe=${_probe_line} > teardown=${_teardown_line})"
else
    fail "run-fleet.sh probe ordering wrong (teardown=${_teardown_line:-?}, probe=${_probe_line:-?})"
fi

# 8. bot-merge.sh probe is skipped in dry-run mode
if grep -q 'DRY_RUN.*gh_api_probe\|gh_api_probe.*DRY_RUN' "$BM"; then
    ok "bot-merge.sh skips probe in dry-run mode"
else
    # Check the block form: if DRY_RUN != 1 guard around gh_api_probe.
    # Use bash [[ == *pattern* ]] to avoid any pipe/SIGPIPE interaction —
    # echo | grep -q has the same broken-pipe problem as awk | grep -q
    # because grep -q exits early on first match, SIGPIPE kills the writer,
    # and set -o pipefail propagates exit 141.
    _awk_out="$(awk '/DRY_RUN.*!= .1/,/gh_api_probe/' "$BM" 2>/dev/null || true)"
    if [[ "$_awk_out" == *gh_api_probe* ]]; then
        ok "bot-merge.sh skips probe in dry-run mode"
    else
        fail "bot-merge.sh should skip probe when DRY_RUN=1"
    fi
fi

# ── CREDIBLE-032: failure-class taxonomy ────────────────────────────────────

# 9. bot-merge.sh emits kind=gh_missing when binary absent
if grep -q '"gh_missing"' "$BM"; then
    ok "bot-merge.sh emits kind=gh_missing"
else
    fail "bot-merge.sh missing gh_missing emit (CREDIBLE-032)"
fi

# 10. bot-merge.sh emits kind=gh_errored when API call fails
if grep -q '"gh_errored"' "$BM"; then
    ok "bot-merge.sh emits kind=gh_errored"
else
    fail "bot-merge.sh missing gh_errored emit (CREDIBLE-032)"
fi

# 11. run-fleet.sh emits kind=gh_missing
if grep -q '"gh_missing"' "$RF"; then
    ok "run-fleet.sh emits kind=gh_missing"
else
    fail "run-fleet.sh missing gh_missing emit (CREDIBLE-032)"
fi

# 12. run-fleet.sh emits kind=gh_errored
if grep -q '"gh_errored"' "$RF"; then
    ok "run-fleet.sh emits kind=gh_errored"
else
    fail "run-fleet.sh missing gh_errored emit (CREDIBLE-032)"
fi

# 13. bot-merge.sh checks `command -v gh` before API call
if grep -q 'command -v gh' "$BM"; then
    ok "bot-merge.sh checks for gh binary (command -v gh)"
else
    fail "bot-merge.sh missing binary presence check (CREDIBLE-032)"
fi

# 14. run-fleet.sh checks `command -v gh` before API call
if grep -q 'command -v gh' "$RF"; then
    ok "run-fleet.sh checks for gh binary (command -v gh)"
else
    fail "run-fleet.sh missing binary presence check (CREDIBLE-032)"
fi

# 15. EVENT_REGISTRY.yaml registers gh_missing kind
ER="$REPO_ROOT/docs/observability/EVENT_REGISTRY.yaml"
if grep -q 'kind: gh_missing' "$ER"; then
    ok "EVENT_REGISTRY.yaml: gh_missing kind registered"
else
    fail "EVENT_REGISTRY.yaml: gh_missing kind missing (CREDIBLE-032)"
fi

# 16. EVENT_REGISTRY.yaml registers gh_errored kind
if grep -q 'kind: gh_errored' "$ER"; then
    ok "EVENT_REGISTRY.yaml: gh_errored kind registered"
else
    fail "EVENT_REGISTRY.yaml: gh_errored kind missing (CREDIBLE-032)"
fi

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
