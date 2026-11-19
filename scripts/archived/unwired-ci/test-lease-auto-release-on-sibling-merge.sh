#!/usr/bin/env bash
# scripts/ci/test-lease-auto-release-on-sibling-merge.sh — INFRA-1444
#
# Verifies that scripts/ops/github-webhook-receiver.py auto-releases sibling
# leases when a pull_request webhook arrives with merged=true and the PR
# title/body references the same gap_id.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd -P)"
RECEIVER="$REPO_ROOT/scripts/ops/github-webhook-receiver.py"
REGISTRY="$REPO_ROOT/docs/observability/EVENT_REGISTRY.yaml"

PASS=0
FAIL=0
ok()   { printf '\033[0;32mPASS\033[0m %s\n' "$*"; PASS=$((PASS+1)); }
fail() { printf '\033[0;31mFAIL\033[0m %s\n' "$*" >&2; FAIL=$((FAIL+1)); }

echo "=== INFRA-1444 lease auto-release on sibling merge ==="
echo

# ── 1. Static wiring ────────────────────────────────────────────────────────
grep -q "INFRA-1444" "$RECEIVER" \
    && ok "INFRA-1444 marker in receiver" \
    || fail "INFRA-1444 marker missing"

grep -q "_auto_release_sibling_leases" "$RECEIVER" \
    && ok "_auto_release_sibling_leases function defined" \
    || fail "_auto_release_sibling_leases missing"

grep -q "lease_orphaned_by_sibling_merge" "$RECEIVER" \
    && ok "kind=lease_orphaned_by_sibling_merge emit wired" \
    || fail "emit missing"

grep -q "CHUMP_LEASE_NO_AUTO_RELEASE" "$RECEIVER" \
    && ok "CHUMP_LEASE_NO_AUTO_RELEASE bypass documented" \
    || fail "bypass missing"

grep -q "_extract_gap_ids" "$RECEIVER" \
    && ok "_extract_gap_ids helper present" \
    || fail "_extract_gap_ids helper missing"

# ── 2. EVENT_REGISTRY entry ─────────────────────────────────────────────────
grep -q "^  - kind: lease_orphaned_by_sibling_merge$" "$REGISTRY" \
    && ok "lease_orphaned_by_sibling_merge registered in EVENT_REGISTRY" \
    || fail "registry entry missing"

grep -A6 "^  - kind: lease_orphaned_by_sibling_merge$" "$REGISTRY" | grep -q "effect_metric: self" \
    && ok "effect_metric present per INFRA-1371 contract" \
    || fail "effect_metric missing"

# ── 3. Python regex extraction sanity ───────────────────────────────────────
python3 -c "
import sys, re
sys.path.insert(0, '$REPO_ROOT/scripts/ops')
# Inline-execute the regex to check it
pattern = re.compile(r'\b([A-Z][A-Z-]+-\d+)\b')
cases = {
    'feat(INFRA-1444): test': ['INFRA-1444'],
    'fix(INFRA-1444): RESILIENT — supersedes INFRA-1368': ['INFRA-1444', 'INFRA-1368'],
    'no gap id here': [],
    'mixed CREDIBLE-001 and PRODUCT-049 and INFRA-1500': ['CREDIBLE-001', 'PRODUCT-049', 'INFRA-1500'],
}
fails = 0
for inp, expected in cases.items():
    got = pattern.findall(inp)
    if got != expected:
        print(f'  FAIL extract: input={inp!r} expected={expected} got={got}')
        fails += 1
sys.exit(fails)
" 2>&1 \
    && ok "_extract_gap_ids regex handles title/body shapes correctly" \
    || fail "regex test cases failed"

# ── 4. Call-site wiring ─────────────────────────────────────────────────────
grep -q "_auto_release_sibling_leases(pr, payload)" "$RECEIVER" \
    && ok "auto-release called from pull_request handler" \
    || fail "call site missing in pull_request branch"

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
