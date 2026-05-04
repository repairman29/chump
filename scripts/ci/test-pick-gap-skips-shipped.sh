#!/usr/bin/env bash
# FLEET-040 — fleet worker must skip a gap whose docs/gaps/<ID>.yaml on
# origin/main is status:done, even when local state.db still says open.
#
# Strategy: static check on worker.sh — the FLEET-040 block must
# (a) be present, (b) git fetch origin main, (c) parse status from the
# YAML on origin/main, (d) `continue` when status==done. Behavioral
# end-to-end (running the fleet) is too heavy for CI; the static pin
# is what we can guarantee here.

set -euo pipefail
PASS=0; FAIL=0
pass() { echo "[PASS] $1"; PASS=$((PASS+1)); }
fail() { echo "[FAIL] $1"; FAIL=$((FAIL+1)); }

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
W="$REPO_ROOT/scripts/dispatch/worker.sh"

[[ -f "$W" ]] || { fail "worker.sh missing"; exit 1; }
pass "worker.sh present"

# 1. FLEET-040 block exists.
grep -q 'FLEET-040: also check origin/main for status:done' "$W" \
    && pass "FLEET-040 block present" \
    || fail "FLEET-040 block missing"

# 2. Fetches origin main.
grep -q 'git fetch origin main --quiet' "$W" \
    && pass "fetches origin main before checking" \
    || fail "missing git fetch origin main"

# 3. Reads YAML from origin/main via git show.
grep -q 'git show "origin/main:docs/gaps/' "$W" \
    && pass "reads docs/gaps/<ID>.yaml from origin/main" \
    || fail "missing git show origin/main:docs/gaps/..."

# 4. Continues (rotates) when status==done.
awk '/FLEET-040: also check/,/continue/' "$W" | grep -q 'continue' \
    && pass "rotates to next candidate when shipped" \
    || fail "missing continue when status==done"

# 5. Behavioral check: simulate the awk parsing on a sample done YAML.
sample=$(cat <<'YAML'
- id: TEST-1
  domain: TEST
  title: a thing
  status: done
  closed_pr: 999
YAML
)
parsed=$(echo "$sample" | awk '/^[[:space:]]*status:[[:space:]]*/{print $2; exit}')
if [[ "$parsed" == "done" ]]; then
    pass "awk parser correctly extracts status: done"
else
    fail "awk parser got '$parsed', expected 'done'"
fi

# 6. Behavioral: open-status YAML must NOT match.
sample_open=$(cat <<'YAML'
- id: TEST-2
  status: open
YAML
)
parsed=$(echo "$sample_open" | awk '/^[[:space:]]*status:[[:space:]]*/{print $2; exit}')
if [[ "$parsed" == "open" ]]; then
    pass "awk parser correctly distinguishes open vs done"
else
    fail "awk parser got '$parsed' for open YAML"
fi

echo ""
echo "Passed: $PASS  Failed: $FAIL"
[ "$FAIL" -eq 0 ]
