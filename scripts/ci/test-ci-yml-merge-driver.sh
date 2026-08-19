#!/usr/bin/env bash
# test-ci-yml-merge-driver.sh — INFRA-1482
#
# Synthetic test cases for the YAML-aware last-resort fallback in
# scripts/git/merge-driver-ci-yml-add-row.sh (scripts/git/ci-yml-yaml-merge.py):
#   1. additive-only diff (pure-append) — still resolves via existing path.
#   2. interleaved additions — ours inserts a step between two steps that
#      theirs also touched (with an unrelated line-shifting edit elsewhere,
#      so the line-diff heuristics give up and the YAML-aware fallback has
#      to carry it) — should auto-resolve with BOTH new steps present.
#   3. both sides modify the SAME step differently — must stay a conflict
#      (driver returns rc=1; no output corruption).
#   4. both sides RENAME the same base step differently — must stay a
#      conflict (ambiguous target, rc=1).
#   5. driver emits kind=merge_driver_fallback when it truly gives up.

set -uo pipefail

PASS=0
FAIL=0
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DRIVER="$REPO_ROOT/scripts/git/merge-driver-ci-yml-add-row.sh"
YAML_MERGE_PY="$REPO_ROOT/scripts/git/ci-yml-yaml-merge.py"

echo "=== INFRA-1482 ci.yml YAML-aware merge driver test ==="

[[ -x "$DRIVER" ]] || { echo "FATAL: $DRIVER missing or not executable"; exit 2; }
[[ -f "$YAML_MERGE_PY" ]] || { echo "FATAL: $YAML_MERGE_PY missing"; exit 2; }
command -v python3 > /dev/null 2>&1 || { echo "FATAL: python3 not on PATH"; exit 2; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export CHUMP_AMBIENT_LOG="$TMP/ambient.jsonl"
: > "$CHUMP_AMBIENT_LOG"

cat > "$TMP/base.yml" <<'EOF'
jobs:
  audit:
    runs-on: ubuntu-latest
    # unrelated comment
    steps:
      - uses: actions/checkout@v6
      - name: step-base-1
        run: bash scripts/ci/test-base-1.sh
      - name: step-base-2
        run: bash scripts/ci/test-base-2.sh
      - name: step-final
        run: bash scripts/ci/test-final.sh
EOF

# ── Case 1: additive-only (pure append at end) — sanity, existing path ────
cp "$TMP/base.yml" "$TMP/c1-ours.yml"
cat >> "$TMP/c1-ours.yml" <<'EOF'
      - name: step-ours-tail
        run: bash scripts/ci/test-ours-tail.sh
EOF
cp "$TMP/base.yml" "$TMP/c1-theirs.yml"
cat >> "$TMP/c1-theirs.yml" <<'EOF'
      - name: step-theirs-tail
        run: bash scripts/ci/test-theirs-tail.sh
EOF
cp "$TMP/c1-ours.yml" "$TMP/c1-work.yml"
: > "$CHUMP_AMBIENT_LOG"
if bash "$DRIVER" "$TMP/base.yml" "$TMP/c1-work.yml" "$TMP/c1-theirs.yml" 1 2>/dev/null; then
    if grep -q "step-ours-tail" "$TMP/c1-work.yml" && grep -q "step-theirs-tail" "$TMP/c1-work.yml"; then
        ok "Case 1: additive-only diff auto-resolves"
    else
        fail "Case 1: merge succeeded but a row is missing"
    fi
else
    fail "Case 1: additive-only diff should have auto-resolved"
fi

# ── Case 2: interleaved additions + an unrelated line-shifting edit ───────
# forces the line-diff heuristics (pure-append + INFRA-1490 patch/union) to
# give up so the YAML-aware fallback has to carry the merge.
python3 - "$TMP/base.yml" "$TMP/c2-ours.yml" "$TMP/c2-theirs.yml" <<'PY'
import sys
base_path, ours_path, theirs_path = sys.argv[1:4]
src = open(base_path).read()

ours = src.replace(
    "      - name: step-base-2\n",
    "      - name: step-ours-mid\n"
    "        run: bash scripts/ci/test-ours-mid.sh\n"
    "      - name: step-base-2\n", 1)
open(ours_path, "w").write(ours)

theirs = src.replace("    # unrelated comment\n", "")
theirs = theirs.replace(
    "      - name: step-base-2\n",
    "      - name: step-theirs-mid\n"
    "        run: bash scripts/ci/test-theirs-mid.sh\n"
    "      - name: step-base-2\n", 1)
open(theirs_path, "w").write(theirs)
PY
cp "$TMP/c2-ours.yml" "$TMP/c2-work.yml"
: > "$CHUMP_AMBIENT_LOG"
rc=0
bash "$DRIVER" "$TMP/base.yml" "$TMP/c2-work.yml" "$TMP/c2-theirs.yml" 1 2>/dev/null || rc=$?
if [[ $rc -eq 0 ]] && grep -q "step-ours-mid" "$TMP/c2-work.yml" && grep -q "step-theirs-mid" "$TMP/c2-work.yml"; then
    ok "Case 2: interleaved additions auto-resolve via YAML-aware fallback"
else
    fail "Case 2: interleaved additions did not auto-resolve (rc=$rc)"
fi
if grep -q '"kind":"ci_yml_row_add_merged"' "$CHUMP_AMBIENT_LOG" && grep -q '"mode":"yaml_aware"' "$CHUMP_AMBIENT_LOG"; then
    ok "Case 2: ambient emits mode=yaml_aware on success"
else
    fail "Case 2: expected ambient ci_yml_row_add_merged mode=yaml_aware event"
fi

# ── Case 3: both sides modify the SAME step differently — stays a conflict ─
python3 - "$TMP/base.yml" "$TMP/c3-ours.yml" "$TMP/c3-theirs.yml" <<'PY'
import sys
base_path, ours_path, theirs_path = sys.argv[1:4]
src = open(base_path).read()
open(ours_path, "w").write(src.replace("test-base-2.sh", "test-base-2-OURS.sh"))
open(theirs_path, "w").write(src.replace("test-base-2.sh", "test-base-2-THEIRS.sh"))
PY
cp "$TMP/c3-ours.yml" "$TMP/c3-work.yml"
: > "$CHUMP_AMBIENT_LOG"
rc=0
bash "$DRIVER" "$TMP/base.yml" "$TMP/c3-work.yml" "$TMP/c3-theirs.yml" 1 2>/dev/null || rc=$?
if [[ $rc -ne 0 ]]; then
    ok "Case 3: same-step-modified-both-sides stays a conflict (rc=$rc)"
else
    fail "Case 3: same-step-modified-both-sides should NOT auto-resolve"
fi
if grep -q '"kind":"merge_driver_fallback"' "$CHUMP_AMBIENT_LOG"; then
    ok "Case 3: ambient emits merge_driver_fallback on give-up"
else
    fail "Case 3: expected ambient merge_driver_fallback event"
fi

# ── Case 4: both sides RENAME the same base step differently — conflict ───
python3 - "$TMP/base.yml" "$TMP/c4-ours.yml" "$TMP/c4-theirs.yml" <<'PY'
import sys
base_path, ours_path, theirs_path = sys.argv[1:4]
src = open(base_path).read()
open(ours_path, "w").write(src.replace("step-base-2", "step-renamed-ours"))
open(theirs_path, "w").write(src.replace("step-base-2", "step-renamed-theirs"))
PY
cp "$TMP/c4-ours.yml" "$TMP/c4-work.yml"
: > "$CHUMP_AMBIENT_LOG"
rc=0
bash "$DRIVER" "$TMP/base.yml" "$TMP/c4-work.yml" "$TMP/c4-theirs.yml" 1 2>/dev/null || rc=$?
if [[ $rc -ne 0 ]]; then
    ok "Case 4: both-sides-renamed-differently stays a conflict (rc=$rc)"
else
    fail "Case 4: both-sides-renamed-differently should NOT auto-resolve"
fi

echo
echo "=== Summary: $PASS passed, $FAIL failed ==="
if [[ $FAIL -eq 0 ]]; then
    echo PASS
    exit 0
else
    echo FAIL
    exit 1
fi
