#!/usr/bin/env bash
# test-design-pass.sh — EFFECTIVE-358
#
# Verifies scripts/design/design-pass.sh spec:
#   1. Writes a spec file with all required sections when claude/chump succeed
#   2. Emits kind=design_pass_spec_emitted with gap_id + spec_path
#   3. Fails loudly (exit 4) + emits kind=design_pass_spec_failed on empty
#      / malformed claude output, instead of writing a broken spec
#   4. Refuses (exit 1) on unknown gap
#   5. Both new event kinds are registered in EVENT_REGISTRY.yaml

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DESIGN_PASS="$REPO_ROOT/scripts/design/design-pass.sh"
CHECKLIST="$REPO_ROOT/docs/design/DESIGN_PASS_CHECKLIST.md"
REGISTRY="$REPO_ROOT/docs/observability/EVENT_REGISTRY.yaml"

[[ -f "$DESIGN_PASS" ]] || { echo "FAIL: missing $DESIGN_PASS"; exit 1; }
[[ -f "$CHECKLIST" ]] || { echo "FAIL: missing $CHECKLIST"; exit 1; }

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "ok: $*"; }

grep -q '^\s*-\s*kind:\s*design_pass_spec_emitted' "$REGISTRY" \
  || fail "design_pass_spec_emitted not registered in EVENT_REGISTRY.yaml"
grep -q '^\s*-\s*kind:\s*design_pass_spec_failed' "$REGISTRY" \
  || fail "design_pass_spec_failed not registered in EVENT_REGISTRY.yaml"
ok "both event kinds registered"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
LOCK_DIR="$TMP/.chump-locks"
mkdir -p "$LOCK_DIR"
AMB="$LOCK_DIR/ambient.jsonl"
SPEC_DIR="$TMP/specs"

SHIM_DIR="$TMP/bin"
mkdir -p "$SHIM_DIR"

CLAUDE_OUTPUT_FILE="$TMP/claude-output.txt"

cat > "$SHIM_DIR/chump" <<'SHIM'
#!/usr/bin/env bash
if [[ "$1 $2" == "gap show" ]]; then
  case "$3" in
    TEST-1)
      cat <<'EOF'
- id: TEST-1
  title: "TEST: some user-facing tool"
  description: |
    A CLI subcommand that prints a report table.
  acceptance_criteria:
    1. Output is readable
EOF
      exit 0
      ;;
    *)
      exit 1
      ;;
  esac
fi
exit 1
SHIM
chmod +x "$SHIM_DIR/chump"

cat > "$SHIM_DIR/claude" <<SHIM
#!/usr/bin/env bash
cat "$CLAUDE_OUTPUT_FILE"
SHIM
chmod +x "$SHIM_DIR/claude"

run_design_pass() {
    env \
        PATH="$SHIM_DIR:/usr/bin:/bin" \
        CHUMP_AMBIENT_LOG="$AMB" \
        CHUMP_LOCK_DIR="$LOCK_DIR" \
        CHUMP_DESIGN_CHECKLIST="$CHECKLIST" \
        CHUMP_DESIGN_SPEC_DIR="$SPEC_DIR" \
        bash "$DESIGN_PASS" "$@"
}

# ── Scenario 1: well-formed claude output → spec written + emitted ─────────
cat > "$CLAUDE_OUTPUT_FILE" <<'EOF'
## Layout
Report table is the single focal element, no competing content.

## Spacing
Consistent 1-blank-line separation between header and rows.

## Typography / output hierarchy
Header row bold/dim-colored, data rows plain.

## Interaction
Empty result set prints "no rows" instead of a blank table.

## Brand-token compliance
N/A — CLI surface, no CSS.

## Consistency with the rest of the product
Matches the table style used by `chump gap list`.

## Consumed by implement
src/cli/report_table.rs
EOF

: > "$AMB"
out_path="$(run_design_pass spec TEST-1)"
[[ -f "$out_path" ]] || fail "spec file was not created at reported path"
grep -q '^## Consumed by implement' "$out_path" || fail "spec missing required section"
grep -q '^# Design spec — TEST-1' "$out_path" || fail "spec missing header"
grep -q '"kind":"design_pass_spec_emitted"' "$AMB" || fail "did not emit design_pass_spec_emitted"
grep -q '"gap_id":"TEST-1"' "$AMB" || fail "ambient event missing gap_id"
grep -q '"spec_path"' "$AMB" || fail "ambient event missing spec_path"
ok "well-formed spec written + emitted"

# ── Scenario 2: empty claude output → fail loudly, no spec written ─────────
: > "$CLAUDE_OUTPUT_FILE"
: > "$AMB"
rm -rf "$SPEC_DIR"
set +e
run_design_pass spec TEST-1 >/tmp/design-pass-scenario2-out.$$ 2>/dev/null
rc=$?
set -e
[[ "$rc" -eq 4 ]] || fail "expected exit 4 on empty claude output, got $rc"
[[ -d "$SPEC_DIR" ]] && [[ -n "$(ls -A "$SPEC_DIR" 2>/dev/null)" ]] && fail "spec dir should be empty/absent on failure"
grep -q '"kind":"design_pass_spec_failed"' "$AMB" || fail "did not emit design_pass_spec_failed"
rm -f /tmp/design-pass-scenario2-out.$$
ok "empty claude output fails loudly, no broken spec written"

# ── Scenario 3: malformed claude output (missing required section) ─────────
cat > "$CLAUDE_OUTPUT_FILE" <<'EOF'
Sure, here's some prose about the design without the right headers.
EOF
: > "$AMB"
set +e
run_design_pass spec TEST-1 >/dev/null 2>/dev/null
rc=$?
set -e
[[ "$rc" -eq 4 ]] || fail "expected exit 4 on malformed claude output, got $rc"
grep -q '"kind":"design_pass_spec_failed"' "$AMB" || fail "did not emit design_pass_spec_failed for malformed output"
ok "malformed claude output fails loudly"

# ── Scenario 4: unknown gap → exit 1, no claude call ────────────────────────
set +e
run_design_pass spec TEST-DOES-NOT-EXIST >/dev/null 2>/dev/null
rc=$?
set -e
[[ "$rc" -eq 1 ]] || fail "expected exit 1 on unknown gap, got $rc"
ok "unknown gap refused with exit 1"

echo
echo "=== test-design-pass.sh PASSED ==="
