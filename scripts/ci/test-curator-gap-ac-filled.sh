#!/usr/bin/env bash
# test-curator-gap-ac-filled.sh — INFRA-983
#
# Verifies Decision 2 (gap_ac_filled) drafts and applies AC for a vague
# pickable gap rather than emitting identified_only.
#
# Stubs `chump` (audit + list + show + set), `claude` (returns canned AC),
# and `gh` on PATH. Asserts:
#   1. Decision 2 calls `claude -p` to draft AC
#   2. Calls `chump gap set --acceptance-criteria` with the drafted AC
#   3. action_taken records "filled INFRA-XXX (count N/3)"
#   4. Daily cap of 3: 4th run records "skipped: daily cap"
#   5. DISABLE env records "disabled: CHUMP_CURATOR_AC_FILL_DISABLE=1"
#   6. Dry-run records "dry_run: would draft AC"
#   7. Malformed LLM output → "error: ..." not "filled ..."

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
CURATOR="$REPO_ROOT/scripts/coord/opus-curator.sh"
[[ -f "$CURATOR" ]] || { echo "FAIL: missing $CURATOR"; exit 1; }

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "ok: $*"; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
LOCK_DIR="$TMP/.chump-locks"
mkdir -p "$LOCK_DIR"
AMB="$LOCK_DIR/ambient.jsonl"
FS="$LOCK_DIR/fleet-state.json"
echo '{}' > "$FS"

CALL_LOG="$TMP/calls.log"
> "$CALL_LOG"

SHIM_DIR="$TMP/bin"
mkdir -p "$SHIM_DIR"

# Chump shim: returns vague_pickable=2, one matching gap, and records 'set'.
cat > "$SHIM_DIR/chump" <<SHIM
#!/usr/bin/env bash
echo "chump \$@" >> "$CALL_LOG"
case "\$1 \$2" in
  "health --slo-check") echo "  pass"; exit 0 ;;
  "waste-tally --window") echo '{"waste_rate":0}'; exit 0 ;;
  "gap audit-priorities") echo '{"p0_count":1,"vague_pickable":2}'; exit 0 ;;
  "gap list")
    cat <<'EOF'
[
  {"id":"INFRA-V1","priority":"P1","effort":"s","depends_on":"","acceptance_criteria":"","created_at":1700000000,"title":"vague gap"},
  {"id":"INFRA-V2","priority":"P1","effort":"m","depends_on":"","acceptance_criteria":"TODO: fill me","created_at":1750000000,"title":"another vague"},
  {"id":"INFRA-OK","priority":"P1","effort":"s","depends_on":"","acceptance_criteria":"do thing|test thing","created_at":1700000000,"title":"already has AC"}
]
EOF
    exit 0 ;;
  "gap show")
    echo "- id: \$3"
    echo "  title: stub title for \$3"
    echo "  description: stub description for \$3"
    exit 0 ;;
  "gap set") exit 0 ;;
  *) echo "{}"; exit 0 ;;
esac
SHIM
chmod +x "$SHIM_DIR/chump"

# Claude shim: respect $CLAUDE_TEST_OUTPUT env to control output.
# IMPORTANT: ${VAR-default} substitutes ONLY when var is unset, not when empty,
# so we can test the empty-output case.
cat > "$SHIM_DIR/claude" <<'SHIM'
#!/usr/bin/env bash
echo "claude $@" >> "$CALL_LOG"
cat >/dev/null
printf '%s' "${CLAUDE_TEST_OUTPUT-add specific file path|assert new behavior with test|emit ambient event for observability|document in CHANGELOG.md}"
SHIM
chmod +x "$SHIM_DIR/claude"

cat > "$SHIM_DIR/gh" <<'SHIM'
#!/usr/bin/env bash
echo 0
SHIM
chmod +x "$SHIM_DIR/gh"

run_curator() {
  env \
    PATH="$SHIM_DIR:/usr/bin:/bin" \
    CHUMP_AMBIENT_LOG="$AMB" \
    CHUMP_FLEET_STATE="$FS" \
    LOCK_DIR="$LOCK_DIR" \
    REPO_ROOT="$REPO_ROOT" \
    HOME="$TMP" \
    CALL_LOG="$CALL_LOG" \
    CLAUDE_TEST_OUTPUT="$1" \
    "${@:2}" \
    bash "$CURATOR" --once 2>&1
}

# ── Scenario 1: happy path — fills AC for INFRA-V1 (oldest) ──────────────────
: > "$AMB"; > "$CALL_LOG"
run_curator "add new module src/foo.rs with public fn bar() taking &str returning Result<String, anyhow::Error>|assert behavior change in tests/foo_test.rs::test_bar_handles_empty_input|emit ambient event kind=foo_ran with fields {ts, kind, input_len, result_len}|document new fn bar() in src/foo.rs doc comment with one short example" >/dev/null
grep -q "^claude -p" "$CALL_LOG" || fail "claude -p was not invoked"
ok "claude -p invoked"
grep -q "^chump gap set INFRA-V1 --acceptance-criteria" "$CALL_LOG" \
  || fail "chump gap set was not called with INFRA-V1: $(cat $CALL_LOG)"
ok "chump gap set INFRA-V1 invoked"
grep -q '"action_taken":"filled INFRA-V1' "$AMB" \
  || fail "action_taken does not record 'filled INFRA-V1': $(grep gap_ac $AMB)"
ok "action_taken records 'filled INFRA-V1 (count N/3)'"

# Marker file written with count=1
[[ -f "$LOCK_DIR/curator-filled-gap_ac-$(date -u +%Y-%m-%d).json" ]] \
  || fail "daily marker file not created"
grep -q '"count":1' "$LOCK_DIR/curator-filled-gap_ac-$(date -u +%Y-%m-%d).json" \
  || fail "marker count != 1"
ok "daily marker created with count=1"

# ── Scenario 2: daily cap — run 3 more times, 4th should skip ────────────────
for i in 2 3; do
  run_curator "add specific implementation in src/foo.rs|assert via test in tests/foo_test.rs covering edge cases|emit kind=foo_processed ambient event|document fn signature and example|verify with cargo test --bin chump foo::tests" >/dev/null
done
# Now count should be 3, 4th run skips.
: > "$AMB"
run_curator "fourth run AC fixture with enough length to exceed the 100-char threshold|verify in tests/foo|emit ambient|document in docs/|expect this to be skipped due to cap" >/dev/null
grep -q '"action_taken":"skipped: daily cap' "$AMB" \
  || fail "4th run did not record daily-cap skip"
ok "4th run respects daily cap of 3"

# ── Scenario 3: DISABLE env ─────────────────────────────────────────────────
rm -f "$LOCK_DIR/curator-filled-gap_ac-"*.json
: > "$AMB"
env \
  PATH="$SHIM_DIR:/usr/bin:/bin" \
  CHUMP_AMBIENT_LOG="$AMB" \
  CHUMP_FLEET_STATE="$FS" \
  LOCK_DIR="$LOCK_DIR" \
  REPO_ROOT="$REPO_ROOT" \
  HOME="$TMP" \
  CHUMP_CURATOR_AC_FILL_DISABLE=1 \
  bash "$CURATOR" --once >/dev/null 2>&1
grep -q '"action_taken":"disabled: CHUMP_CURATOR_AC_FILL_DISABLE=1' "$AMB" \
  || fail "DISABLE did not record disabled action_taken"
ok "CHUMP_CURATOR_AC_FILL_DISABLE=1 short-circuits"

# ── Scenario 4: dry-run does NOT call claude ────────────────────────────────
: > "$AMB"; > "$CALL_LOG"
env \
  PATH="$SHIM_DIR:/usr/bin:/bin" \
  CHUMP_AMBIENT_LOG="$AMB" \
  CHUMP_FLEET_STATE="$FS" \
  LOCK_DIR="$LOCK_DIR" \
  REPO_ROOT="$REPO_ROOT" \
  HOME="$TMP" \
  bash "$CURATOR" --once --dry-run >/dev/null 2>&1
if grep -q "^claude -p" "$CALL_LOG"; then
  fail "dry-run still called claude -p"
fi
grep -q '"action_taken":"dry_run: would draft AC' "$AMB" \
  || fail "dry-run did not record dry_run action_taken"
ok "dry-run does not call claude; records dry_run action_taken"

# ── Scenario 5: malformed LLM output → error fallback ───────────────────────
rm -f "$LOCK_DIR/curator-filled-gap_ac-"*.json
: > "$AMB"; > "$CALL_LOG"
# Empty output from claude.
run_curator "" >/dev/null
grep -q '"action_taken":"error: LLM returned' "$AMB" \
  || fail "empty LLM output did not record error action_taken"
ok "empty LLM output → error action_taken (no AC applied)"

# Output without | separator.
rm -f "$LOCK_DIR/curator-filled-gap_ac-"*.json
: > "$AMB"
run_curator "this is just one long sentence with no pipe separator at all" >/dev/null
grep -q '"action_taken":"error: LLM returned' "$AMB" \
  || fail "no-pipe LLM output did not record error"
ok "LLM output without pipe separator → error action_taken"

echo
echo "=== test-curator-gap-ac-filled.sh PASSED ==="
