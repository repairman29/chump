#!/usr/bin/env bash
# test-ci-yml-add-row-adjacent.sh — INFRA-1490
#
# Verifies the ci.yml merge driver's NEW patch-based fallback for
# mid-file additions:
#   1. Pure-append case (existing behavior) still works.
#   2. Two adjacent mid-file additions auto-merge cleanly via patch fuzz.
#   3. A real edit in theirs (delete or modify line) still fails to merge
#      (regression guard — driver only handles ADD-ONLY diffs).
#   4. Driver emits kind=ci_yml_row_add_merged when the patch path succeeds.

set -uo pipefail

PASS=0
FAIL=0
FAILS=()
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); FAILS+=("$1"); }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DRIVER="$REPO_ROOT/scripts/git/merge-driver-ci-yml-add-row.sh"

echo "=== INFRA-1490 ci.yml merge driver mid-file fallback ==="

[[ -x "$DRIVER" ]] || { echo "FAIL: $DRIVER missing"; exit 2; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export CHUMP_AMBIENT_LOG="$TMP/ambient.jsonl"
: > "$CHUMP_AMBIENT_LOG"

# Base file: a tiny ci.yml-shaped fixture.
cat > "$TMP/base.yml" <<'EOF'
jobs:
  audit:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v6
      - name: step-base-1
        run: bash scripts/ci/test-base-1.sh
      - name: step-base-2
        run: bash scripts/ci/test-base-2.sh
      - name: step-final
        run: bash scripts/ci/test-final.sh
EOF

# ── AC #1: pure-append (existing behavior — both branches APPEND at end) ───
cp "$TMP/base.yml" "$TMP/ours-1.yml"
cat >> "$TMP/ours-1.yml" <<'EOF'
      - name: step-ours
        run: bash scripts/ci/test-ours.sh
EOF
cp "$TMP/base.yml" "$TMP/theirs-1.yml"
cat >> "$TMP/theirs-1.yml" <<'EOF'
      - name: step-theirs
        run: bash scripts/ci/test-theirs.sh
EOF
cp "$TMP/ours-1.yml" "$TMP/work-1.yml"
if bash "$DRIVER" "$TMP/base.yml" "$TMP/work-1.yml" "$TMP/theirs-1.yml" 1 2>/dev/null; then
    if grep -q "step-ours" "$TMP/work-1.yml" && grep -q "step-theirs" "$TMP/work-1.yml"; then
        ok "AC #1: pure-append both rows present after merge"
    else
        fail "AC #1: merge succeeded but rows missing"
    fi
else
    fail "AC #1: pure-append path no longer works (regression)"
fi

# ── AC #2: mid-file adjacent insert (NEW patch fallback) ──────────────────
# Ours adds row BETWEEN step-base-1 and step-base-2.
sed 's|step-base-2|step-ours\n        run: bash scripts/ci/test-ours.sh\n      - name: step-base-2|' \
    "$TMP/base.yml" > "$TMP/ours-2.yml" 2>/dev/null
# Theirs adds DIFFERENT row also between step-base-1 and step-base-2.
# Use python to do the insertion cleanly (sed multi-line is brittle).
python3 - <<PY
import re
src = open("$TMP/base.yml").read()
# Insert 'theirs' row right BEFORE step-base-2 (same as where ours added, mid-file).
new = src.replace(
    "      - name: step-base-2\n",
    "      - name: step-theirs\n"
    "        run: bash scripts/ci/test-theirs.sh\n"
    "      - name: step-base-2\n", 1)
open("$TMP/theirs-2.yml", "w").write(new)
# Same insertion shape for ours.
new2 = src.replace(
    "      - name: step-base-2\n",
    "      - name: step-ours\n"
    "        run: bash scripts/ci/test-ours.sh\n"
    "      - name: step-base-2\n", 1)
open("$TMP/ours-2.yml", "w").write(new2)
PY
cp "$TMP/ours-2.yml" "$TMP/work-2.yml"
if bash "$DRIVER" "$TMP/base.yml" "$TMP/work-2.yml" "$TMP/theirs-2.yml" 1 2>"$TMP/err-2"; then
    if grep -q "step-ours" "$TMP/work-2.yml" && grep -q "step-theirs" "$TMP/work-2.yml"; then
        ok "AC #2: mid-file adjacent additions auto-merged"
    else
        fail "AC #2: merge claimed success but a row is missing"
        echo "--- work-2.yml ---" >&2
        cat "$TMP/work-2.yml" >&2
    fi
else
    fail "AC #2: mid-file adjacent additions NOT auto-merged (driver returned non-zero)"
    cat "$TMP/err-2" >&2
fi

# ── AC #4: ambient emit on successful patch-based merge ───────────────────
if grep -q '"kind":"ci_yml_row_add_merged"' "$CHUMP_AMBIENT_LOG"; then
    ok "AC #4: driver emits kind=ci_yml_row_add_merged on patch success"
else
    fail "AC #4: patch-based merge did NOT emit audit event"
fi

# ── AC #3: regression — theirs DELETES a line → driver refuses ────────────
cp "$TMP/base.yml" "$TMP/theirs-3.yml"
sed -i.bak '/step-base-1/,/step-base-1/d' "$TMP/theirs-3.yml" 2>/dev/null || \
    python3 -c "
src = open('$TMP/base.yml').read()
open('$TMP/theirs-3.yml','w').write(src.replace('      - name: step-base-1\n        run: bash scripts/ci/test-base-1.sh\n',''))
"
rm -f "$TMP/theirs-3.yml.bak" 2>/dev/null
cp "$TMP/base.yml" "$TMP/work-3.yml"
if bash "$DRIVER" "$TMP/base.yml" "$TMP/work-3.yml" "$TMP/theirs-3.yml" 1 2>/dev/null; then
    fail "AC #3: driver auto-merged a theirs-DELETE — regression!"
else
    ok "AC #3: driver refuses to merge theirs-with-DELETE (returns 1)"
fi

echo
echo "=== Summary: $PASS passed, $FAIL failed ==="
if (( FAIL > 0 )); then
    for f in "${FAILS[@]}"; do printf '  - %s\n' "$f"; done
    exit 1
fi
echo "PASS"
