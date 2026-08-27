#!/usr/bin/env bash
# test-gap-opened-date-coverage.sh — INFRA-1611
#
# Guards the P0 aging census (chump gap audit-priorities, CLAUDE.md Mission
# Driver "P0 budget = 5 max") against going blind again: asserts that no
# open P0 or P1 gap in the committed docs/gaps/*.yaml dump is missing (or
# has a placeholder) opened_date.
#
# Runs against docs/gaps/*.yaml rather than .chump/state.db because
# state.db is gitignored and not present on a fresh CI checkout.

set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
cd "$REPO_ROOT"

PASS=0
FAIL=0
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

echo "=== INFRA-1611 gap opened_date coverage test ==="
echo

# 1. Backfill script exists (INFRA-1611 AC#2 companions).
if [[ -x scripts/dev/backfill-opened-dates.sh ]]; then
    ok "scripts/dev/backfill-opened-dates.sh present + executable (state.db backfill)"
else
    fail "scripts/dev/backfill-opened-dates.sh missing or not executable"
fi

if [[ -x scripts/dev/backfill-yaml-opened-dates.sh ]]; then
    ok "scripts/dev/backfill-yaml-opened-dates.sh present + executable (YAML backfill)"
else
    fail "scripts/dev/backfill-yaml-opened-dates.sh missing or not executable"
fi

# 2. `gap reserve` stamps opened_date at reservation time (INFRA-1611 AC#1).
if grep -q 'opened_date' crates/chump-gap-store/src/lib.rs \
    && grep -q 'unix_to_iso_date' crates/chump-gap-store/src/lib.rs; then
    ok "reserve() stamps opened_date via unix_to_iso_date"
else
    fail "reserve() does not appear to stamp opened_date"
fi

# 3. Coverage check: no open P0/P1 gap missing or with a placeholder
#    opened_date (INFRA-1611 AC#4).
MISSING=0
declare -a MISSING_IDS=()
PLACEHOLDER_RE='^(0000-00-00|1970-01-01|TBD|TODO|)$'

for f in docs/gaps/*.yaml; do
    [[ -f "$f" ]] || continue
    status="$(grep -m1 '^  status:' "$f" | awk '{print $2}' || true)"
    [[ "$status" != "open" ]] && continue
    priority="$(grep -m1 '^  priority:' "$f" | awk '{print $2}' || true)"
    [[ "$priority" != "P0" && "$priority" != "P1" ]] && continue

    opened_date="$(grep -m1 '^  opened_date:' "$f" | sed 's/^  opened_date: *//' | tr -d '"'"'" || true)"
    if [[ -z "$opened_date" ]] || [[ "$opened_date" =~ $PLACEHOLDER_RE ]]; then
        gap_id="$(grep -m1 '^- id:' "$f" | sed 's/^- id: *//')"
        MISSING_IDS+=("${gap_id:-$f}")
        MISSING=$((MISSING + 1))
    fi
done

if [[ "$MISSING" -eq 0 ]]; then
    ok "no open P0/P1 gap missing or with placeholder opened_date"
else
    fail "$MISSING open P0/P1 gap(s) missing or with placeholder opened_date: ${MISSING_IDS[*]}"
    echo "  fix: bash scripts/dev/backfill-yaml-opened-dates.sh"
fi

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
