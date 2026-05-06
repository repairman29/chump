#!/usr/bin/env bash
# test-waste-tally-by-domain.sh — INFRA-574
#
# Static-validates the --by-domain flag on chump waste-tally:
#  (a) build_report_by_domain pub fn exists
#  (b) DomainEntry / WasteByDomainReport structs exist
#  (c) --by-domain flag wired in main.rs
#  (d) domain_from_gap_id helper present
#  (e) infra574_ unit tests defined

set -euo pipefail

PASS=0
FAIL=0
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

REPO_ROOT="$(git rev-parse --show-toplevel)"

echo "=== INFRA-574 waste-tally --by-domain plumbing test ==="
echo

# 1. build_report_by_domain pub fn.
if grep -qE "pub fn build_report_by_domain\b" "$REPO_ROOT/src/waste_tally.rs"; then
    ok "pub fn build_report_by_domain exists"
else
    fail "pub fn build_report_by_domain missing"
fi

# 2. WasteByDomainReport struct.
if grep -q "WasteByDomainReport" "$REPO_ROOT/src/waste_tally.rs"; then
    ok "WasteByDomainReport struct exists"
else
    fail "WasteByDomainReport struct missing"
fi

# 3. DomainEntry struct.
if grep -q "DomainEntry" "$REPO_ROOT/src/waste_tally.rs"; then
    ok "DomainEntry struct exists"
else
    fail "DomainEntry struct missing"
fi

# 4. domain_from_gap_id helper.
if grep -q "fn domain_from_gap_id" "$REPO_ROOT/src/waste_tally.rs"; then
    ok "domain_from_gap_id helper present"
else
    fail "domain_from_gap_id helper missing"
fi

# 5. --by-domain flag wired in main.rs.
if grep -q "by.domain" "$REPO_ROOT/src/main.rs"; then
    ok "--by-domain flag wired in main.rs"
else
    fail "--by-domain flag not wired in main.rs"
fi

# 6. build_report_by_domain called in main.rs.
if grep -q "build_report_by_domain" "$REPO_ROOT/src/main.rs"; then
    ok "build_report_by_domain called in main.rs"
else
    fail "build_report_by_domain not called in main.rs"
fi

# 7. render_text and render_json on WasteByDomainReport.
for method in render_text render_json; do
    if grep -qE "fn ${method}" "$REPO_ROOT/src/waste_tally.rs"; then
        ok "WasteByDomainReport::${method} exists"
    else
        fail "WasteByDomainReport::${method} missing"
    fi
done

# 8. infra574_ unit tests defined (need >=4).
test_count=$(grep -cE 'fn infra574_' "$REPO_ROOT/src/waste_tally.rs" 2>/dev/null || echo 0)
if [[ "$test_count" -ge 4 ]]; then
    ok "infra574_ unit tests defined ($test_count fns)"
else
    fail "expected >=4 infra574_ unit tests, found $test_count"
fi

# 9. UNKNOWN bucket handling in domain_from_gap_id (smoke check via grep).
if grep -q '"UNKNOWN"' "$REPO_ROOT/src/waste_tally.rs"; then
    ok "UNKNOWN fallback domain present"
else
    fail "UNKNOWN fallback domain missing"
fi

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
