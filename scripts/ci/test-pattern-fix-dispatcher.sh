#!/usr/bin/env bash
# INFRA-2355 (META-269 sub-6): integration test for pattern-fix-dispatcher.
#
# Validates the known-failure-pattern -> fix-script auto-fix path with a
# synthetic pattern + synthetic CI-failure log, entirely inside a throwaway
# git repo (no network, no real gh calls):
#
#   Scenario A: synthetic log matches the synthetic pattern's regex
#       -> fix-script runs, changes are made, dry-run skips PR
#       -> exit 0, ambient has pattern_fix_matched + pattern_fix_applied
#          + pattern_fix_dry_run.
#
#   Scenario B: synthetic log does NOT match any pattern
#       -> exit 3, ambient has pattern_fix_no_match, no fix-script run.
#
#   Scenario C: pattern matches but the fix-script fails
#       -> exit 2, ambient has pattern_fix_failed with exit_code.
#
#   Scenario D: pattern's regex has a capture group
#       -> the captured value is passed as $1 to the fix-script.
set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
DISPATCHER="$REPO_ROOT/scripts/coord/pattern-fix-dispatcher.sh"

if [ ! -x "$DISPATCHER" ]; then
  echo "FAIL: dispatcher not executable: $DISPATCHER" >&2
  exit 1
fi

TMPDIR=$(mktemp -d -t pattern-fix-dispatcher-test-XXXXXX)
trap 'rm -rf "$TMPDIR"' EXIT

errors=0

# ── Throwaway git repo so the dispatcher's git diff/checkout logic has a
#    real (but disposable) working tree to operate on. ──────────────────────
SANDBOX="$TMPDIR/sandbox-repo"
mkdir -p "$SANDBOX"
git -C "$SANDBOX" init -q
git -C "$SANDBOX" config user.email "test@example.com"
git -C "$SANDBOX" config user.name "pattern-fix-test"
echo "seed" > "$SANDBOX/seed.txt"
git -C "$SANDBOX" add seed.txt
git -C "$SANDBOX" commit -q -m "seed"

run_dispatcher() {
  local patterns_file="$1" log_content="$2" dry_run="$3" ambient_file="$4"
  ( cd "$SANDBOX" && \
    CHUMP_PATTERN_FIX_PATTERNS_FILE="$patterns_file" \
    CHUMP_PATTERN_FIX_AMBIENT_FILE="$ambient_file" \
    CHUMP_PATTERN_FIX_DRY_RUN="$dry_run" \
    bash "$DISPATCHER" - <<< "$log_content" )
}

# ── Scenario A: match + fix-script applies a change + dry-run ───────────────
FIX_STUB_A="$TMPDIR/fix-stub-a.sh"
cat > "$FIX_STUB_A" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
echo "fixed" >> "$(git rev-parse --show-toplevel)/seed.txt"
EOF
chmod +x "$FIX_STUB_A"

PATTERNS_A="$TMPDIR/patterns-a.yaml"
cat > "$PATTERNS_A" <<EOF
version: 1
patterns:
  - name: synthetic_known_failure
    description: "test-only synthetic failure marker"
    match_regex: "SYNTHETIC_KNOWN_FAILURE_MARKER"
    fix_script: $FIX_STUB_A
EOF

AMBIENT_A="$TMPDIR/ambient-a.jsonl"
rc_a=0
run_dispatcher "$PATTERNS_A" "some CI noise
error: SYNTHETIC_KNOWN_FAILURE_MARKER detected in job foo
more noise" "1" "$AMBIENT_A" > "$TMPDIR/out-a.log" 2>&1 || rc_a=$?

if [ "$rc_a" -ne 0 ]; then
  echo "FAIL scenario A: expected exit 0, got $rc_a" >&2
  cat "$TMPDIR/out-a.log" >&2
  errors=$((errors + 1))
elif ! grep -q '"kind":"pattern_fix_matched"' "$AMBIENT_A" \
  || ! grep -q '"kind":"pattern_fix_applied"' "$AMBIENT_A" \
  || ! grep -q '"kind":"pattern_fix_dry_run"' "$AMBIENT_A"; then
  echo "FAIL scenario A: expected matched+applied+dry_run ambient events; got:" >&2
  cat "$AMBIENT_A" >&2
  errors=$((errors + 1))
elif ! grep -q "^fixed$" "$SANDBOX/seed.txt"; then
  echo "FAIL scenario A: fix-script did not run (seed.txt unchanged)" >&2
  errors=$((errors + 1))
else
  echo "PASS scenario A: synthetic known-pattern triggered the auto-fix path (dry-run)"
fi

# Reset sandbox for next scenario.
git -C "$SANDBOX" checkout -q -- seed.txt

# ── Scenario B: no pattern matches ───────────────────────────────────────────
AMBIENT_B="$TMPDIR/ambient-b.jsonl"
rc_b=0
run_dispatcher "$PATTERNS_A" "totally unrelated CI output, nothing to see here" "1" "$AMBIENT_B" > "$TMPDIR/out-b.log" 2>&1 || rc_b=$?

if [ "$rc_b" -ne 3 ]; then
  echo "FAIL scenario B: expected exit 3 (no match), got $rc_b" >&2
  cat "$TMPDIR/out-b.log" >&2
  errors=$((errors + 1))
elif ! grep -q '"kind":"pattern_fix_no_match"' "$AMBIENT_B"; then
  echo "FAIL scenario B: expected pattern_fix_no_match ambient event; got:" >&2
  cat "$AMBIENT_B" >&2
  errors=$((errors + 1))
else
  echo "PASS scenario B: unmatched log -> no auto-fix dispatched"
fi

# ── Scenario C: pattern matches but fix-script fails ─────────────────────────
FIX_STUB_C="$TMPDIR/fix-stub-c.sh"
cat > "$FIX_STUB_C" <<'EOF'
#!/usr/bin/env bash
exit 7
EOF
chmod +x "$FIX_STUB_C"

PATTERNS_C="$TMPDIR/patterns-c.yaml"
cat > "$PATTERNS_C" <<EOF
version: 1
patterns:
  - name: synthetic_failing_fix
    description: "test-only pattern whose fix-script always fails"
    match_regex: "SYNTHETIC_FAILING_FIX_MARKER"
    fix_script: $FIX_STUB_C
EOF

AMBIENT_C="$TMPDIR/ambient-c.jsonl"
rc_c=0
run_dispatcher "$PATTERNS_C" "error: SYNTHETIC_FAILING_FIX_MARKER seen" "1" "$AMBIENT_C" > "$TMPDIR/out-c.log" 2>&1 || rc_c=$?

if [ "$rc_c" -ne 2 ]; then
  echo "FAIL scenario C: expected exit 2 (fix-script failed), got $rc_c" >&2
  cat "$TMPDIR/out-c.log" >&2
  errors=$((errors + 1))
elif ! grep -q '"kind":"pattern_fix_failed"' "$AMBIENT_C" || ! grep -q '"exit_code":7' "$AMBIENT_C"; then
  echo "FAIL scenario C: expected pattern_fix_failed with exit_code:7; got:" >&2
  cat "$AMBIENT_C" >&2
  errors=$((errors + 1))
else
  echo "PASS scenario C: failing fix-script surfaces pattern_fix_failed"
fi

# ── Scenario D: capture group passed as $1 to fix-script ────────────────────
FIX_STUB_D="$TMPDIR/fix-stub-d.sh"
cat > "$FIX_STUB_D" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
echo "captured:${1:-}" >> "$(git rev-parse --show-toplevel)/seed.txt"
EOF
chmod +x "$FIX_STUB_D"

PATTERNS_D="$TMPDIR/patterns-d.yaml"
cat > "$PATTERNS_D" <<EOF
version: 1
patterns:
  - name: synthetic_capture_group
    description: "test-only pattern with a capture group"
    match_regex: "SYNTHETIC_PATH_MARKER: (.+)"
    fix_script: $FIX_STUB_D
EOF

AMBIENT_D="$TMPDIR/ambient-d.jsonl"
rc_d=0
run_dispatcher "$PATTERNS_D" "error: SYNTHETIC_PATH_MARKER: docs/foo/bar.yaml" "1" "$AMBIENT_D" > "$TMPDIR/out-d.log" 2>&1 || rc_d=$?

if [ "$rc_d" -ne 0 ]; then
  echo "FAIL scenario D: expected exit 0, got $rc_d" >&2
  cat "$TMPDIR/out-d.log" >&2
  errors=$((errors + 1))
elif ! grep -q "^captured:docs/foo/bar.yaml$" "$SANDBOX/seed.txt"; then
  echo "FAIL scenario D: capture group not passed to fix-script; seed.txt:" >&2
  cat "$SANDBOX/seed.txt" >&2
  errors=$((errors + 1))
else
  echo "PASS scenario D: regex capture group passed through to fix-script as \$1"
fi

if [ "$errors" -gt 0 ]; then
  echo "test-pattern-fix-dispatcher: $errors scenario(s) failed" >&2
  exit 1
fi

echo "test-pattern-fix-dispatcher: PASS — all 4 scenarios validated"
