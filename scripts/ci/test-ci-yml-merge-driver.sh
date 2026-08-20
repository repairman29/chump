#!/usr/bin/env bash
# test-ci-yml-merge-driver.sh — INFRA-1482
#
# Tests the YAML-aware last-resort fallback (scripts/git/ci-yml-yaml-merge.py)
# wired into scripts/git/merge-driver-ci-yml-add-row.sh. Covers the case the
# line-diff heuristics can't resolve: interleaved additions where ours inserts
# a step between two steps that theirs also touched in the same job.
# shellcheck disable=SC2015  # ok() always exits 0; A && ok || fail is safe here
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DRIVER="$REPO_ROOT/scripts/git/merge-driver-ci-yml-add-row.sh"

PASS=0; FAIL=0
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

echo "=== INFRA-1482 ci.yml YAML-aware merge driver test ==="
echo

[[ -x "$DRIVER" ]] || { echo "FATAL: driver not found or not executable: $DRIVER"; exit 2; }
command -v python3 > /dev/null 2>&1 || { echo "FATAL: python3 not found"; exit 2; }

TMPBASE="$(mktemp -d)"
AMB="$TMPBASE/ambient.jsonl"
export CHUMP_AMBIENT_LOG="$AMB"
trap 'rm -rf "$TMPBASE"' EXIT

# ── Test 1: additive-only (both append after the same last step) ────────────
echo "--- Test 1: additive-only, both append ---"
T1="$TMPBASE/t1"; mkdir -p "$T1"
cat > "$T1/ancestor.yml" <<'EOF'
jobs:
  ci:
    steps:
      - name: checkout
        uses: actions/checkout@v4
      - name: build
        run: echo build
EOF
cat > "$T1/ours.yml" <<'EOF'
jobs:
  ci:
    steps:
      - name: checkout
        uses: actions/checkout@v4
      - name: build
        run: echo build
      - name: ours-step
        run: echo ours
EOF
cat > "$T1/theirs.yml" <<'EOF'
jobs:
  ci:
    steps:
      - name: checkout
        uses: actions/checkout@v4
      - name: build
        run: echo build
      - name: theirs-step
        run: echo theirs
EOF
rc=0; "$DRIVER" "$T1/ancestor.yml" "$T1/ours.yml" "$T1/theirs.yml" 2>/dev/null || rc=$?
[[ $rc -eq 0 ]] && ok "additive-only auto-resolves (rc=0)" || fail "additive-only should resolve (got $rc)"
python3 -c "import yaml,sys; yaml.safe_load(open('$T1/ours.yml'))" 2>/dev/null \
  && ok "additive-only merged output is valid YAML" || fail "additive-only merged output is NOT valid YAML"
grep -q 'ours-step' "$T1/ours.yml" && grep -q 'theirs-step' "$T1/ours.yml" \
  && ok "additive-only merged output contains both new steps" \
  || fail "additive-only merged output missing a new step"

# ── Test 2: interleaved additions — ours inserts between two theirs-touched steps ──
echo "--- Test 2: interleaved additions (the reported #2088 case) ---"
T2="$TMPBASE/t2"; mkdir -p "$T2"
cat > "$T2/ancestor.yml" <<'EOF'
jobs:
  ci:
    steps:
      - name: checkout
        uses: actions/checkout@v4
      - name: setup
        run: echo setup
      - name: build
        run: echo build
      - name: test
        run: echo test
      - name: lint
        run: echo lint
EOF
cat > "$T2/ours.yml" <<'EOF'
jobs:
  ci:
    steps:
      - name: checkout
        uses: actions/checkout@v4
      - name: setup
        run: echo setup
      - name: ours-added-step
        run: echo ours
      - name: build
        run: echo build
      - name: test
        run: echo test
      - name: lint
        run: echo lint
EOF
cat > "$T2/theirs.yml" <<'EOF'
jobs:
  ci:
    steps:
      - name: checkout
        uses: actions/checkout@v4
      - name: setup
        run: echo setup
      - name: build
        run: echo build
      - name: theirs-added-step
        run: echo theirs
      - name: test
        run: echo test
      - name: lint
        run: echo lint --strict
EOF
rc=0; "$DRIVER" "$T2/ancestor.yml" "$T2/ours.yml" "$T2/theirs.yml" 2>/dev/null || rc=$?
[[ $rc -eq 0 ]] && ok "interleaved additions auto-resolve via YAML-aware fallback (rc=0)" \
  || fail "interleaved additions should auto-resolve (got $rc)"
python3 -c "import yaml,sys; yaml.safe_load(open('$T2/ours.yml'))" 2>/dev/null \
  && ok "interleaved merged output is valid YAML" || fail "interleaved merged output is NOT valid YAML"
grep -q 'ours-added-step' "$T2/ours.yml" && grep -q 'theirs-added-step' "$T2/ours.yml" \
  && ok "interleaved merged output contains both new steps" \
  || fail "interleaved merged output missing a new step"
grep -q -- '--strict' "$T2/ours.yml" \
  && ok "interleaved merge carried theirs' single-side edit to lint step" \
  || fail "interleaved merge lost theirs' edit to lint step"

# ── Test 3: both sides modify the SAME step differently → keep conflict ─────
echo "--- Test 3: same-step conflicting modification (must NOT auto-resolve) ---"
T3="$TMPBASE/t3"; mkdir -p "$T3"
cat > "$T3/ancestor.yml" <<'EOF'
jobs:
  ci:
    steps:
      - name: checkout
        uses: actions/checkout@v4
      - name: build
        run: echo build
EOF
cat > "$T3/ours.yml" <<'EOF'
jobs:
  ci:
    steps:
      - name: checkout
        uses: actions/checkout@v4
      - name: build
        run: echo build --ours
EOF
cat > "$T3/theirs.yml" <<'EOF'
jobs:
  ci:
    steps:
      - name: checkout
        uses: actions/checkout@v4
      - name: build
        run: echo build --theirs
EOF
before_ours="$(cat "$T3/ours.yml")"
rc=0; "$DRIVER" "$T3/ancestor.yml" "$T3/ours.yml" "$T3/theirs.yml" 2>/dev/null || rc=$?
[[ $rc -ne 0 ]] && ok "conflicting same-step edits refused (non-zero rc)" \
  || fail "conflicting same-step edits should be refused (got rc=0)"
[[ "$(cat "$T3/ours.yml")" == "$before_ours" ]] \
  && ok "ours.yml left untouched on refusal" \
  || fail "ours.yml was mutated despite refusal"

# ── Test 4: both sides rename the same step (ambiguous) → keep conflict ─────
echo "--- Test 4: both rename the same base step (must NOT auto-resolve) ---"
T4="$TMPBASE/t4"; mkdir -p "$T4"
cat > "$T4/ancestor.yml" <<'EOF'
jobs:
  ci:
    steps:
      - name: checkout
        uses: actions/checkout@v4
      - name: build
        run: echo build
EOF
cat > "$T4/ours.yml" <<'EOF'
jobs:
  ci:
    steps:
      - name: checkout
        uses: actions/checkout@v4
      - name: build-ours-renamed
        run: echo build
EOF
cat > "$T4/theirs.yml" <<'EOF'
jobs:
  ci:
    steps:
      - name: checkout
        uses: actions/checkout@v4
      - name: build-theirs-renamed
        run: echo build
EOF
rc=0; "$DRIVER" "$T4/ancestor.yml" "$T4/ours.yml" "$T4/theirs.yml" 2>/dev/null || rc=$?
[[ $rc -ne 0 ]] && ok "both-sides rename refused (non-zero rc)" \
  || fail "both-sides rename of the same base step should be refused (got rc=0)"

# ── Test 5: give_up() emits kind=merge_driver_fallback on true refusal ──────
echo "--- Test 5: ambient emission on refusal ---"
grep -q '"kind":"merge_driver_fallback"' "$AMB" 2>/dev/null \
  && ok "kind=merge_driver_fallback emitted to ambient log on refusal" \
  || fail "kind=merge_driver_fallback NOT emitted on refusal"

# ── Source assertions ────────────────────────────────────────────────────────
echo "--- Source assertions ---"
grep -q 'ci-yml-yaml-merge.py' "$DRIVER" \
  && ok "driver wires in the YAML-aware fallback script" \
  || fail "driver does NOT reference ci-yml-yaml-merge.py"
[[ -f "$REPO_ROOT/scripts/git/ci-yml-yaml-merge.py" ]] \
  && ok "ci-yml-yaml-merge.py exists" \
  || fail "ci-yml-yaml-merge.py NOT found"
grep -q 'merge_driver_fallback' "$DRIVER" \
  && ok "driver references merge_driver_fallback ambient kind" \
  || fail "driver does NOT reference merge_driver_fallback"

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
