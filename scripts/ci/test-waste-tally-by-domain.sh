#!/usr/bin/env bash
# test-waste-tally-by-domain.sh — INFRA-574
#
# Static-validates the --by-domain flag on chump waste-tally:
#  (a) build_domain_report / WasteDomainReport exist and are pub
#  (b) --by-domain flag wired in main.rs waste-tally handler
#  (c) domain_from_gap_id helper present
#  (d) in-tree infra574_ unit tests defined
#  (e) render_text / render_json impl on WasteDomainReport

set -euo pipefail

PASS=0
FAIL=0
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

REPO_ROOT="$(git rev-parse --show-toplevel)"

echo "=== INFRA-574 waste-tally --by-domain test ==="
echo

# (a) WasteDomainReport and build_domain_report are public.
if grep -qE 'pub struct WasteDomainReport' "$REPO_ROOT/src/waste_tally.rs"; then
    ok "pub struct WasteDomainReport exists"
else
    fail "WasteDomainReport missing or not pub"
fi

if grep -qE 'pub fn build_domain_report\b' "$REPO_ROOT/src/waste_tally.rs"; then
    ok "pub fn build_domain_report exists"
else
    fail "build_domain_report missing or not pub"
fi

if grep -qE 'pub struct WasteDomainEntry' "$REPO_ROOT/src/waste_tally.rs"; then
    ok "pub struct WasteDomainEntry exists"
else
    fail "WasteDomainEntry missing or not pub"
fi

# (b) --by-domain wired in main.rs.
if grep -q 'by.domain' "$REPO_ROOT/src/main.rs" "$REPO_ROOT/src/commands/dispatch_gap.rs"; then
    ok "--by-domain flag wired in main.rs"
else
    fail "--by-domain not wired in main.rs"
fi

if grep -q 'build_domain_report' "$REPO_ROOT/src/main.rs" "$REPO_ROOT/src/commands/dispatch_gap.rs"; then
    ok "build_domain_report called from main.rs"
else
    fail "build_domain_report not called from main.rs"
fi

# (c) domain_from_gap_id helper.
if grep -qE 'fn domain_from_gap_id' "$REPO_ROOT/src/waste_tally.rs"; then
    ok "domain_from_gap_id helper present"
else
    fail "domain_from_gap_id helper missing"
fi

# (d) infra574_ unit tests.
test_count=$(grep -cE 'fn infra574_' "$REPO_ROOT/src/waste_tally.rs" 2>/dev/null || echo 0)
if [[ "$test_count" -ge 3 ]]; then
    ok "infra574_ unit tests defined ($test_count fns)"
else
    fail "expected >=3 infra574_ unit tests, found $test_count"
fi

# (e) render_text and render_json on WasteDomainReport.
if grep -qE 'impl WasteDomainReport' "$REPO_ROOT/src/waste_tally.rs"; then
    ok "impl WasteDomainReport block exists"
else
    fail "impl WasteDomainReport missing"
fi

if grep -q 'fn render_text' "$REPO_ROOT/src/waste_tally.rs" && \
   grep -q 'fn render_json' "$REPO_ROOT/src/waste_tally.rs"; then
    ok "render_text and render_json both present"
else
    fail "render_text or render_json missing on WasteDomainReport"
fi

# (f) Domains sorted by incidents descending (smoke: sort_by_key Reverse).
if grep -q 'Reverse(e.incidents)' "$REPO_ROOT/src/waste_tally.rs"; then
    ok "domain list sorted by incidents descending"
else
    fail "domain sort by incidents descending not found"
fi

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
