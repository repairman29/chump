#!/usr/bin/env bash
# test-infra-689-closed-gap-archive.sh — INFRA-689 tests.
#
# Verifies that closed (done) gap YAMLs live in docs/gaps/closed/ and
# that docs/gaps/ contains only non-done gaps.
#
#   (1) docs/gaps/closed/ directory exists
#   (2) every YAML in docs/gaps/*.yaml has status != done
#   (3) every YAML in docs/gaps/closed/*.yaml has status = done
#   (4) docs/gaps/ still contains open gaps (not empty)
#   (5) briefing.rs has closed-path fallback (INFRA-689 code change)
#   (6) closed fallback searches docs/gaps/closed/<ID>.yaml
#   (7) at least 50 files archived (verifies migration ran, not just structure)
#   (8) no duplicate IDs across open and closed directories
#
# Run: ./scripts/ci/test-infra-689-closed-gap-archive.sh

set -uo pipefail

PASS=0
FAIL=0
FAILS=()

ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); FAILS+=("$1"); }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
GAPS_DIR="$REPO_ROOT/docs/gaps"
CLOSED_DIR="$REPO_ROOT/docs/gaps/closed"
BRIEFING_RS="$REPO_ROOT/src/briefing.rs"

echo "=== INFRA-689 closed gap archive tests ==="
echo

# ── Test 1: docs/gaps/closed/ directory exists ───────────────────────────────
echo "--- Test 1: docs/gaps/closed/ directory exists ---"
if [[ -d "$CLOSED_DIR" ]]; then
    ok "Test 1: docs/gaps/closed/ exists"
else
    fail "Test 1: docs/gaps/closed/ directory missing"
fi

# ── Test 2: no done YAMLs left in docs/gaps/*.yaml ───────────────────────────
echo "--- Test 2: docs/gaps/*.yaml contains no done-status gaps ---"
_done_in_open=$(python3 - <<PYEOF 2>/dev/null
import os, yaml
gaps = "$GAPS_DIR"
found = 0
for f in os.listdir(gaps):
    if not f.endswith('.yaml') or f == 'gaps.yaml':
        continue
    path = f'{gaps}/{f}'
    try:
        d = yaml.safe_load(open(path))
        if isinstance(d, list): d = d[0]
        if d and d.get('status') == 'done':
            found += 1
            print(f, end=' ')
    except:
        pass
import sys
if found:
    print(f'\ntotal={found}', file=sys.stderr)
print(found)
PYEOF
)
if [[ "${_done_in_open:-0}" -eq 0 ]]; then
    ok "Test 2: no done-status YAMLs remain in docs/gaps/"
else
    fail "Test 2: ${_done_in_open} done-status YAML(s) still in docs/gaps/"
fi

# ── Test 3: every YAML in closed/ has status=done ─────────────────────────────
echo "--- Test 3: all docs/gaps/closed/*.yaml have status=done ---"
_non_done_in_closed=$(python3 - <<PYEOF 2>/dev/null
import os, yaml
closed = "$CLOSED_DIR"
if not os.path.isdir(closed):
    print(0)
    exit()
found = 0
for f in os.listdir(closed):
    if not f.endswith('.yaml'):
        continue
    path = f'{closed}/{f}'
    try:
        d = yaml.safe_load(open(path))
        if isinstance(d, list): d = d[0]
        if d and d.get('status') != 'done':
            found += 1
    except:
        pass
print(found)
PYEOF
)
if [[ "${_non_done_in_closed:-1}" -eq 0 ]]; then
    ok "Test 3: all closed/ YAMLs have status=done"
else
    fail "Test 3: ${_non_done_in_closed} non-done YAML(s) found in docs/gaps/closed/"
fi

# ── Test 4: docs/gaps/ still has open gaps ───────────────────────────────────
echo "--- Test 4: docs/gaps/ still contains open gaps ---"
_open_count=$(ls "$GAPS_DIR"/*.yaml 2>/dev/null | grep -v closed | wc -l | tr -d ' ')
if [[ "${_open_count:-0}" -gt 0 ]]; then
    ok "Test 4: docs/gaps/ has ${_open_count} non-closed YAML files"
else
    fail "Test 4: docs/gaps/ appears empty — open gaps may have been incorrectly moved"
fi

# ── Test 5: briefing.rs has the INFRA-689 closed-path fallback ───────────────
echo "--- Test 5: briefing.rs checks docs/gaps/closed/ as fallback ---"
if grep -q 'INFRA-689' "$BRIEFING_RS" 2>/dev/null; then
    ok "Test 5: briefing.rs has INFRA-689 closed-path fallback"
else
    fail "Test 5: INFRA-689 fallback missing from briefing.rs"
fi

# ── Test 6: closed path searches docs/gaps/closed/<ID>.yaml ──────────────────
echo "--- Test 6: briefing.rs fallback path is docs/gaps/closed ---"
if grep -q '"docs/gaps/closed"' "$BRIEFING_RS" 2>/dev/null || \
   grep -q 'gaps/closed' "$BRIEFING_RS" 2>/dev/null; then
    ok "Test 6: briefing.rs fallback uses docs/gaps/closed/<ID>.yaml"
else
    fail "Test 6: docs/gaps/closed path not found in briefing.rs"
fi

# ── Test 7: at least 50 files archived ───────────────────────────────────────
echo "--- Test 7: at least 50 done YAMLs archived in closed/ ---"
_closed_count=$(ls "$CLOSED_DIR"/*.yaml 2>/dev/null | wc -l | tr -d ' ')
if [[ "${_closed_count:-0}" -ge 50 ]]; then
    ok "Test 7: ${_closed_count} done YAMLs archived in docs/gaps/closed/"
else
    fail "Test 7: only ${_closed_count} files in closed/ — migration may not have run"
fi

# ── Test 8: no duplicate IDs across open and closed dirs ──────────────────────
echo "--- Test 8: no duplicate gap IDs across docs/gaps/ and docs/gaps/closed/ ---"
_dupes=$(python3 - <<PYEOF 2>/dev/null
import os
gaps = "$GAPS_DIR"
closed = "$CLOSED_DIR"
open_ids = {f[:-5] for f in os.listdir(gaps) if f.endswith('.yaml') and f != 'gaps.yaml'}
closed_ids = {f[:-5] for f in os.listdir(closed) if f.endswith('.yaml')} if os.path.isdir(closed) else set()
dupes = open_ids & closed_ids
print(len(dupes))
if dupes:
    import sys
    print(sorted(dupes)[:5], file=sys.stderr)
PYEOF
)
if [[ "${_dupes:-0}" -eq 0 ]]; then
    ok "Test 8: no duplicate gap IDs across open and closed directories"
else
    fail "Test 8: ${_dupes} duplicate gap ID(s) found in both dirs"
fi

# ── Summary ───────────────────────────────────────────────────────────────────
echo
echo "=== Results: $PASS passed, $FAIL failed ==="
if [[ $FAIL -gt 0 ]]; then
    for f in "${FAILS[@]}"; do echo "  - $f"; done
    exit 1
fi
exit 0
