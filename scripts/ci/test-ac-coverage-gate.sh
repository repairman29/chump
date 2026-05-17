#!/usr/bin/env bash
# test-ac-coverage-gate.sh — INFRA-1541 smoke test
#
# Three fixtures driving scripts/ci/test-pr-ac-coverage.sh:
#   1. full-coverage   — every AC bullet hits via path or symbol; exits 0; no misses
#   2. missing-bullet  — one AC uncovered; advisory mode exits 0 + emits
#                        kind=ac_coverage_miss; blocking mode exits 1
#   3. waiver          — uncovered bullet waived; emits kind=ac_coverage_waived
#                        and exits 0 in blocking mode (no miss)
#
# Plus operator-override and no-gap-ref pass-through checks.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
GATE="$REPO_ROOT/scripts/ci/test-pr-ac-coverage.sh"

[[ -x "$GATE" ]] || { echo "FAIL: missing or non-executable $GATE"; exit 1; }

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "ok: $*"; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/.chump-locks"
AMB="$TMP/.chump-locks/ambient.jsonl"

SHIM_DIR="$TMP/bin"
mkdir -p "$SHIM_DIR"

# Default gh shim — overridden per fixture.
GH_FIXTURE="$TMP/gh-fixture.json"
GH_DIFF="$TMP/gh-diff.patch"
echo '{"title":"","body":"","files":[],"commits":[]}' > "$GH_FIXTURE"
> "$GH_DIFF"

cat > "$SHIM_DIR/gh" <<'SHIM'
#!/usr/bin/env bash
case "$1 $2" in
  "pr view")
    # gh pr view <N> --json title,body,files,commits
    cat "$GH_FIXTURE"
    ;;
  "pr diff")
    cat "$GH_DIFF"
    ;;
  *)
    echo "{}"
    ;;
esac
SHIM
chmod +x "$SHIM_DIR/gh"

# chump shim: returns AC bullets from a JSON file (or empty so script
# falls back to docs/gaps/<ID>.yaml).
CHUMP_AC_JSON="$TMP/chump-gap-show.json"
echo '{}' > "$CHUMP_AC_JSON"
cat > "$SHIM_DIR/chump" <<'SHIM'
#!/usr/bin/env bash
if [[ "$1 $2" == "gap show" ]]; then
  cat "$CHUMP_AC_JSON"
  exit 0
fi
echo "{}"
SHIM
chmod +x "$SHIM_DIR/chump"

run_gate() {
  env \
    PATH="$SHIM_DIR:/usr/bin:/bin" \
    CHUMP_AMBIENT_LOG="$AMB" \
    GH_FIXTURE="$GH_FIXTURE" \
    GH_DIFF="$GH_DIFF" \
    CHUMP_AC_JSON="$CHUMP_AC_JSON" \
    CHUMP_AC_GATE_ENABLED="${CHUMP_AC_GATE_ENABLED:-true}" \
    CHUMP_AC_GATE_BLOCKING="${CHUMP_AC_GATE_BLOCKING:-false}" \
    "${@:1}" \
    bash "$GATE" "${PR_NUMBER:-9999}"
}

# Helpers to install a gap AC + PR fixture.
set_gap_ac() {
  local id="$1"; shift
  local ac_json
  ac_json="$(printf '%s\n' "$@" | jq -R . | jq -s '. | tostring')"
  jq -n --arg id "$id" --arg ac "$(printf '%s\n' "$@" | jq -R . | jq -s .)" \
    '{id:$id, acceptance_criteria:$ac}' \
    | jq --argjson ac "$(printf '%s\n' "$@" | jq -R . | jq -s .)" \
        '.acceptance_criteria = ($ac | tostring)' \
    > "$CHUMP_AC_JSON"
}

set_pr_fixture() {
  local title="$1"; local body="$2"; shift 2
  # remaining args are file paths
  local files_json
  files_json="$(printf '%s\n' "$@" | jq -R '{path: .}' | jq -s .)"
  jq -n \
    --arg title "$title" \
    --arg body "$body" \
    --argjson files "$files_json" \
    '{title:$title, body:$body, files:$files, commits:[{messageHeadline:$title, messageBody:$body}]}' \
    > "$GH_FIXTURE"
}

# ── Fixture 1: full coverage ─────────────────────────────────────────────────
echo
echo "=== Fixture 1: full-coverage ==="
: > "$AMB"
set_gap_ac "INFRA-9001" \
  "Add scripts/foo/bar.sh with kind=foo_ran emit" \
  "Wire --enable-foo CLI flag into src/main.rs"
set_pr_fixture "feat(INFRA-9001): add foo bar" "body" \
  "scripts/foo/bar.sh" "src/main.rs"
# diff text must contain --enable-foo and kind=foo_ran for symbol coverage
printf -- "--- a/src/main.rs\n+++ b/src/main.rs\n+        --enable-foo => run_foo(),\n+        kind=foo_ran\n" > "$GH_DIFF"

PR_NUMBER=9001 run_gate >"$TMP/out1.txt" 2>&1
rc=$?
cat "$TMP/out1.txt"
[[ $rc -eq 0 ]] || fail "fixture 1 expected exit 0, got $rc"
grep -q "MISS" "$TMP/out1.txt" && fail "fixture 1 should have no misses"
grep -q '"kind":"ac_coverage_miss"' "$AMB" && fail "fixture 1 should not emit ac_coverage_miss"
ok "fixture 1 full coverage: exit 0, no misses, no miss emits"

# ── Fixture 2: missing bullet (advisory mode → exit 0; blocking → exit 1) ────
echo
echo "=== Fixture 2: missing-bullet ==="
: > "$AMB"
set_gap_ac "INFRA-9002" \
  "Add scripts/foo/baz.sh emit kind=baz_ran" \
  "Implement uncovered_widget feature in src/widgets.rs"
set_pr_fixture "feat(INFRA-9002): partial coverage" "body" \
  "scripts/foo/baz.sh"
printf -- "--- a/scripts/foo/baz.sh\n+++ b/scripts/foo/baz.sh\n+kind=baz_ran\n" > "$GH_DIFF"

# advisory mode
PR_NUMBER=9002 CHUMP_AC_GATE_BLOCKING=false run_gate >"$TMP/out2.txt" 2>&1
rc=$?
cat "$TMP/out2.txt"
[[ $rc -eq 0 ]] || fail "fixture 2 advisory expected exit 0, got $rc"
grep -q "MISS" "$TMP/out2.txt" || fail "fixture 2 should print a MISS line"
grep -q '"kind":"ac_coverage_miss"' "$AMB" \
  || fail "fixture 2 should emit kind=ac_coverage_miss"
# JSON shape: pr_number, gap_id, bullet_index, bullet_text_prefix
grep -q '"pr_number":"9002"' "$AMB" || fail "miss event missing pr_number=9002"
grep -q '"gap_id":"INFRA-9002"' "$AMB" || fail "miss event missing gap_id"
grep -q '"bullet_index":"2"' "$AMB" || fail "miss event missing bullet_index"
grep -q '"bullet_text_prefix":' "$AMB" || fail "miss event missing bullet_text_prefix"
ok "fixture 2 advisory mode: exit 0, emit kind=ac_coverage_miss with full JSON shape"

# blocking mode
: > "$AMB"
PR_NUMBER=9002 CHUMP_AC_GATE_BLOCKING=true run_gate >"$TMP/out2b.txt" 2>&1
rc=$?
cat "$TMP/out2b.txt"
[[ $rc -eq 1 ]] || fail "fixture 2 blocking expected exit 1, got $rc"
grep -q "BLOCKING mode: failing" "$TMP/out2b.txt" \
  || fail "fixture 2 blocking should print failing message"
ok "fixture 2 blocking mode: exit 1, miss-list printed"

# ── Fixture 3: waiver bypass ─────────────────────────────────────────────────
echo
echo "=== Fixture 3: waiver-bypass ==="
: > "$AMB"
set_gap_ac "INFRA-9003" \
  "Add scripts/qux/run.sh covering kind=qux_ran" \
  "Implement totally_uncovered_thing in src/thing.rs"
set_pr_fixture "feat(INFRA-9003): partial with waiver" \
  "We waive the second AC because the runtime piece moved to follow-up.
AC-Coverage-Waive: 2: deferred to INFRA-9004 follow-up" \
  "scripts/qux/run.sh"
printf -- "--- a/scripts/qux/run.sh\n+++ b/scripts/qux/run.sh\n+kind=qux_ran\n" > "$GH_DIFF"

# blocking mode should still pass thanks to waiver
PR_NUMBER=9003 CHUMP_AC_GATE_BLOCKING=true run_gate >"$TMP/out3.txt" 2>&1
rc=$?
cat "$TMP/out3.txt"
[[ $rc -eq 0 ]] || fail "fixture 3 waiver+blocking expected exit 0, got $rc"
grep -q "WAIVED" "$TMP/out3.txt" || fail "fixture 3 should print WAIVED for AC 2"
grep -q '"kind":"ac_coverage_waived"' "$AMB" \
  || fail "fixture 3 should emit kind=ac_coverage_waived"
grep -q '"reason":"deferred to INFRA-9004 follow-up"' "$AMB" \
  || fail "fixture 3 waiver event must carry reason"
grep -q '"kind":"ac_coverage_miss"' "$AMB" \
  && fail "fixture 3 should NOT emit ac_coverage_miss for the waived bullet"
ok "fixture 3 waiver bypass: exit 0, emit kind=ac_coverage_waived with reason"

# ── Operator-override: CHUMP_AC_GATE_ENABLED=false short-circuits ────────────
echo
echo "=== Fixture 4: operator override (gate disabled) ==="
: > "$AMB"
set_gap_ac "INFRA-9004" "totally uncovered bullet"
set_pr_fixture "feat(INFRA-9004): no work" "body" "README.md"
PR_NUMBER=9004 CHUMP_AC_GATE_BLOCKING=true CHUMP_AC_GATE_ENABLED=false \
  run_gate >"$TMP/out4.txt" 2>&1
rc=$?
[[ $rc -eq 0 ]] || fail "fixture 4 gate-disabled expected exit 0, got $rc"
grep -q '"kind":"ac_coverage_disabled"' "$AMB" \
  || fail "fixture 4 should emit kind=ac_coverage_disabled"
ok "fixture 4 gate disabled: exit 0, emit kind=ac_coverage_disabled"

# ── No-gap-ref pass-through ──────────────────────────────────────────────────
echo
echo "=== Fixture 5: no gap ref in title ==="
: > "$AMB"
set_pr_fixture "chore: docs cleanup" "body" "README.md"
PR_NUMBER=9005 CHUMP_AC_GATE_BLOCKING=true run_gate >"$TMP/out5.txt" 2>&1
rc=$?
[[ $rc -eq 0 ]] || fail "fixture 5 no-gap-ref expected exit 0, got $rc"
grep -q "no_gap_ref" "$TMP/out5.txt" \
  || fail "fixture 5 should print no_gap_ref note"
ok "fixture 5 no-gap-ref: exit 0, pass-through note"

echo
echo "=== test-ac-coverage-gate.sh PASSED ==="
