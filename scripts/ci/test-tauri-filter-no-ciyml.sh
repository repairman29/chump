#!/usr/bin/env bash
# CI regression guard: INFRA-1421
#
# Asserts that .github/workflows/ci.yml is NOT listed in the `tauri:`
# paths-filter block of ci.yml itself.
#
# History: PR #2065 fixed a bug where ci.yml was accidentally added to the
# tauri paths-filter, causing the tauri-cowork-e2e job to run on EVERY PR
# that touched ci.yml (including unrelated gap fixes, docs edits, etc.).
# Within hours of the fix, another PR merged ci.yml back in. This guard
# prevents that regression from silently re-entering.
#
# CI-Regression-Guard: scripts/ci/test-tauri-filter-no-ciyml.sh

set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
CI_YML="$REPO_ROOT/.github/workflows/ci.yml"
PASS=0; FAIL=0

ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

echo "=== INFRA-1421 tauri-filter regression guard ==="
echo

# ── Parse the `tauri:` paths-filter block ────────────────────────────────────
# Use Python for reliable indentation-aware extraction.
# Captures consecutive '- item' lines immediately after the tauri: key.
TAURI_BLOCK=$(python3 - "$CI_YML" <<'PYEOF'
import sys
with open(sys.argv[1]) as f:
    lines = f.readlines()
# Find the paths-filter tauri: block — the one whose NEXT non-blank line is a list entry.
# Skip tauri: assignments like `tauri: ${{ ... }}`.
in_tauri = False
tauri_indent = 0
for i, line in enumerate(lines):
    stripped = line.lstrip()
    indent = len(line) - len(stripped)
    if stripped.startswith('tauri:') and stripped.strip() == 'tauri:':
        # Confirm next non-blank line is a list entry (- 'pattern').
        for j in range(i + 1, min(i + 5, len(lines))):
            ns = lines[j].lstrip()
            if ns.strip() == '' or ns.startswith('#'):
                continue
            if ns.startswith('- '):
                in_tauri = True
                tauri_indent = indent
            break
        if not in_tauri:
            continue
        continue
    if in_tauri:
        if stripped.startswith('- ') and indent > tauri_indent:
            print(line, end='')
        elif indent <= tauri_indent and stripped.strip() and not stripped.startswith('#'):
            break
PYEOF
)

echo "Tauri paths-filter entries found:"
echo "$TAURI_BLOCK" | sed 's/^/  /'
echo

# ── Assertion: ci.yml must NOT appear ────────────────────────────────────────
if echo "$TAURI_BLOCK" | grep -qF ".github/workflows/ci.yml"; then
    fail ".github/workflows/ci.yml IS in the tauri: paths-filter (regression detected!)"
    echo
    echo "  Fix: remove '.github/workflows/ci.yml' from the 'tauri:' block in ci.yml."
    echo "  Offending lines:"
    echo "$TAURI_BLOCK" | grep "ci.yml" | sed 's/^/    /'
else
    ok ".github/workflows/ci.yml is NOT in the tauri: paths-filter"
fi

# ── Sanity: tauri block must still have its legitimate entries ───────────────
if echo "$TAURI_BLOCK" | grep -q "e2e-tauri"; then
    ok "tauri block still contains e2e-tauri/** (sanity check)"
else
    fail "tauri block is missing e2e-tauri/** — the filter may have been removed entirely"
fi

if echo "$TAURI_BLOCK" | grep -q "desktop"; then
    ok "tauri block still contains desktop/** (sanity check)"
else
    fail "tauri block is missing desktop/** — the filter may have been emptied"
fi

# ── Summary ───────────────────────────────────────────────────────────────────
echo
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
