#!/usr/bin/env bash
# test-ci-yml-merge-driver.sh — INFRA-1482
#
# Regression suite for the YAML-aware merge layer
# (scripts/git/ci-yml-yaml-merge.py) added to the ci-yml-add-row merge
# driver. Covers: additive-only diffs, INTERLEAVED additions (the case the
# line-diff heuristics couldn't resolve — the motivating bug for this gap),
# both-modify-same-step (keep conflict), and both-rename (keep conflict).

set -uo pipefail

PASS=0
FAIL=0
FAILS=()
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); FAILS+=("$1"); }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DRIVER="$REPO_ROOT/scripts/git/merge-driver-ci-yml-add-row.sh"
YAML_MERGE="$REPO_ROOT/scripts/git/ci-yml-yaml-merge.py"

echo "=== INFRA-1482 ci.yml YAML-aware merge driver test ==="

[[ -x "$DRIVER" ]] || { echo "FATAL: $DRIVER missing or not executable"; exit 2; }
[[ -f "$YAML_MERGE" ]] || { echo "FATAL: $YAML_MERGE missing"; exit 2; }
command -v python3 >/dev/null 2>&1 || { echo "FATAL: python3 not found"; exit 2; }
python3 -c 'import yaml' >/dev/null 2>&1 || { echo "FATAL: PyYAML not importable"; exit 2; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export CHUMP_AMBIENT_LOG="$TMP/ambient.jsonl"
: > "$CHUMP_AMBIENT_LOG"

base_fixture() {
  cat <<'EOF'
name: ci
on:
  push:
    branches: [main]
jobs:
  audit:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: step-A
        run: bash scripts/ci/test-a.sh
      - name: step-B
        run: bash scripts/ci/test-b.sh
      - name: step-final
        run: bash scripts/ci/test-final.sh
EOF
}

# ── Test 1: additive-only, both sides append at EOF (pure-append, handled
#    by the pre-existing pure-append path too, but must still work) ───────
echo "--- Test 1: additive-only (both append distinct steps at EOF) ---"
T1="$TMP/t1"; mkdir -p "$T1"
base_fixture > "$T1/ancestor.yml"
cp "$T1/ancestor.yml" "$T1/ours.yml"
cp "$T1/ancestor.yml" "$T1/theirs.yml"
cat >> "$T1/ours.yml"   <<'EOF'
      - name: step-ours
        run: bash scripts/ci/test-ours.sh
EOF
cat >> "$T1/theirs.yml" <<'EOF'
      - name: step-theirs
        run: bash scripts/ci/test-theirs.sh
EOF
rc=0; "$DRIVER" "$T1/ancestor.yml" "$T1/ours.yml" "$T1/theirs.yml" 2>/dev/null || rc=$?
if [[ $rc -eq 0 ]] && grep -q 'step-ours' "$T1/ours.yml" && grep -q 'step-theirs' "$T1/ours.yml" \
   && python3 -c "import yaml,sys; yaml.safe_load(open('$T1/ours.yml'))" 2>/dev/null; then
  ok "additive-only: both steps present, valid YAML"
else
  fail "additive-only: merge failed or produced invalid YAML (rc=$rc)"
fi

# ── Test 2: INTERLEAVED additions — ours inserts a step BETWEEN two steps
#    that main (theirs) independently inserted. This is the motivating bug:
#    the line-diff heuristics see this as a conflict; the YAML-aware layer
#    must resolve it by step identity. ──────────────────────────────────
echo "--- Test 2: interleaved additions (INFRA-1482 motivating case) ---"
T2="$TMP/t2"; mkdir -p "$T2"
base_fixture > "$T2/ancestor.yml"
# theirs (main) adds TWO new steps around step-B: one before, one after.
python3 - "$T2/ancestor.yml" "$T2/theirs.yml" <<'PY'
import sys
src = open(sys.argv[1]).read()
new = src.replace(
    "      - name: step-B\n        run: bash scripts/ci/test-b.sh\n",
    "      - name: step-main-before\n"
    "        run: bash scripts/ci/test-main-before.sh\n"
    "      - name: step-B\n        run: bash scripts/ci/test-b.sh\n"
    "      - name: step-main-after\n"
    "        run: bash scripts/ci/test-main-after.sh\n")
open(sys.argv[2], "w").write(new)
PY
# ours inserts a step BETWEEN step-A and step-B (i.e. it would land between
# step-main-before and step-B once rebased onto theirs).
python3 - "$T2/ancestor.yml" "$T2/ours.yml" <<'PY'
import sys
src = open(sys.argv[1]).read()
new = src.replace(
    "      - name: step-B\n",
    "      - name: step-ours-mid\n"
    "        run: bash scripts/ci/test-ours-mid.sh\n"
    "      - name: step-B\n")
open(sys.argv[2], "w").write(new)
PY
cp "$T2/ours.yml" "$T2/work.yml"
rc=0; "$DRIVER" "$T2/ancestor.yml" "$T2/work.yml" "$T2/theirs.yml" 2>"$TMP/t2.err" || rc=$?
if [[ $rc -eq 0 ]] \
   && grep -q 'step-main-before' "$T2/work.yml" \
   && grep -q 'step-main-after'  "$T2/work.yml" \
   && grep -q 'step-ours-mid'    "$T2/work.yml" \
   && grep -q 'step-A' "$T2/work.yml" && grep -q 'step-B' "$T2/work.yml" \
   && python3 -c "import yaml; yaml.safe_load(open('$T2/work.yml'))" 2>/dev/null; then
  ok "interleaved additions auto-resolve via YAML-aware merge"
else
  fail "interleaved additions did NOT auto-resolve (rc=$rc)"
  cat "$TMP/t2.err" >&2
  cat "$T2/work.yml" >&2
fi
if grep -q '"mode":"yaml_aware"' "$CHUMP_AMBIENT_LOG"; then
  ok "ambient emits mode=yaml_aware for the interleaved case"
else
  fail "no yaml_aware ambient emit recorded for interleaved case"
fi

# ── Test 3: both sides modify the SAME existing step differently — keep
#    conflict (driver must NOT silently pick one side). ────────────────
echo "--- Test 3: both modify same step differently -> conflict kept ---"
T3="$TMP/t3"; mkdir -p "$T3"
base_fixture > "$T3/ancestor.yml"
sed 's/test-a.sh/test-a.sh --ours/' "$T3/ancestor.yml" > "$T3/ours.yml"
sed 's/test-a.sh/test-a.sh --theirs/' "$T3/ancestor.yml" > "$T3/theirs.yml"
cp "$T3/ours.yml" "$T3/work.yml"
rc=0; "$DRIVER" "$T3/ancestor.yml" "$T3/work.yml" "$T3/theirs.yml" 2>/dev/null || rc=$?
[[ $rc -ne 0 ]] \
  && ok "both-modify-same-step: driver refuses (rc=$rc), conflict kept for human/3-way" \
  || fail "both-modify-same-step: driver should refuse, got rc=0"

# ── Test 4: both sides RENAME the same step differently — keep conflict ──
echo "--- Test 4: both rename same step differently -> conflict kept ---"
T4="$TMP/t4"; mkdir -p "$T4"
base_fixture > "$T4/ancestor.yml"
sed 's/name: step-A/name: step-A-renamed-ours/' "$T4/ancestor.yml" > "$T4/ours.yml"
sed 's/name: step-A/name: step-A-renamed-theirs/' "$T4/ancestor.yml" > "$T4/theirs.yml"
cp "$T4/ours.yml" "$T4/work.yml"
rc=0; "$DRIVER" "$T4/ancestor.yml" "$T4/work.yml" "$T4/theirs.yml" 2>/dev/null || rc=$?
[[ $rc -ne 0 ]] \
  && ok "both-rename-same-step: driver refuses (rc=$rc), conflict kept for human/3-way" \
  || fail "both-rename-same-step: driver should refuse, got rc=0"
if grep -q '"kind":"merge_driver_fallback"' "$CHUMP_AMBIENT_LOG"; then
  ok "ambient emits kind=merge_driver_fallback when driver gives up"
else
  fail "no merge_driver_fallback ambient emit recorded"
fi

# ── Test 5: direct unit check of ci-yml-yaml-merge.py exit codes ─────────
echo "--- Test 5: ci-yml-yaml-merge.py exits 2 (not-applicable) on non-YAML input ---"
T5="$TMP/t5"; mkdir -p "$T5"
printf 'not: [valid\n' > "$T5/bad.yml"
cp "$T5/bad.yml" "$T5/ours.yml"
cp "$T5/bad.yml" "$T5/theirs.yml"
rc=0; python3 "$YAML_MERGE" "$T5/bad.yml" "$T5/ours.yml" "$T5/theirs.yml" 2>/dev/null || rc=$?
[[ $rc -eq 2 ]] \
  && ok "invalid YAML input -> exit 2 (not applicable)" \
  || fail "expected exit 2 for invalid YAML, got $rc"

echo
echo "=== Summary: $PASS passed, $FAIL failed ==="
if (( FAIL > 0 )); then
  for f in "${FAILS[@]}"; do printf '  - %s\n' "$f"; done
  exit 1
fi
echo "PASS"
