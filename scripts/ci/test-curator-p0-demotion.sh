#!/usr/bin/env bash
# test-curator-p0-demotion.sh — INFRA-978
#
# Smoke-test that the curator's Decision 1 actually mutates state when
# P0_COUNT > 5, rather than emitting identified_only as it did before
# this gap shipped.
#
# Strategy: extract Decision-1 block from opus-curator.sh and exercise
# it directly with a stubbed `chump` on PATH that returns canned data,
# then assert the emitted curator_decision event has a real action_taken
# string ("demoted INFRA-XXX") not the identified_only placeholder.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
CURATOR="$REPO_ROOT/scripts/coord/opus-curator.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "ok: $*"; }

[[ -f "$CURATOR" ]] || fail "missing $CURATOR"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
LOCK_DIR="$TMP/.chump-locks"
mkdir -p "$LOCK_DIR"
AMB="$LOCK_DIR/ambient.jsonl"
FS="$LOCK_DIR/fleet-state.json"
echo '{}' > "$FS"

# Build a shim `chump` that returns canned audit + gap-list output.
SHIM_DIR="$TMP/bin"
mkdir -p "$SHIM_DIR"
cat > "$SHIM_DIR/chump" <<'SHIM'
#!/usr/bin/env bash
case "$1" in
  gap)
    case "$2" in
      audit-priorities)
        # Always say P0=6 (over budget) so the curator triggers demotion.
        echo '{"p0_count":6,"vague_pickable":0}'
        ;;
      list)
        # Six P0s with different created_at values; oldest is INFRA-OLDEST.
        cat <<'EOF'
[
  {"id":"INFRA-OLDEST","priority":"P0","status":"open","created_at":1700000000,"title":"oldest P0"},
  {"id":"INFRA-MID-A","priority":"P0","status":"open","created_at":1750000000,"title":"mid P0 a"},
  {"id":"INFRA-MID-B","priority":"P0","status":"open","created_at":1760000000,"title":"mid P0 b"},
  {"id":"INFRA-MID-C","priority":"P0","status":"open","created_at":1770000000,"title":"mid P0 c"},
  {"id":"INFRA-MID-D","priority":"P0","status":"open","created_at":1775000000,"title":"mid P0 d"},
  {"id":"INFRA-NEW","priority":"P0","status":"open","created_at":1778000000,"title":"newest P0"},
  {"id":"INFRA-P1","priority":"P1","status":"open","created_at":1700000000,"title":"P1 (should not be demoted)"}
]
EOF
        ;;
      set)
        # Record the demotion to a sentinel file the test will inspect.
        echo "DEMOTED: $3 $4 $5" >> "$CHUMP_TEST_DEMOTION_LOG"
        exit 0
        ;;
      *) echo '{}' ;;
    esac
    ;;
  health|waste-tally) exit 0 ;;
  *) echo "shim: unknown args: $*" >&2; exit 99 ;;
esac
SHIM
chmod +x "$SHIM_DIR/chump"

DEMOTION_LOG="$TMP/demotion.log"
> "$DEMOTION_LOG"

# Run the curator's Decision 1 block. The shell script reads various env
# vars and writes to AMBIENT, so we point those at our TMP.
RUN_OUTPUT=$(env \
  PATH="$SHIM_DIR:$PATH" \
  CHUMP_AMBIENT_LOG="$AMB" \
  CHUMP_FLEET_STATE="$FS" \
  CHUMP_TEST_DEMOTION_LOG="$DEMOTION_LOG" \
  REPO_ROOT="$REPO_ROOT" \
  bash "$CURATOR" --once --dry-run 2>&1 || true)

# Even in --dry-run we expect the curator to log the would-be demotion
# with action_taken NOT == "identified_only".
echo "$RUN_OUTPUT" | grep -q "Decision 1:" || fail "curator did not run Decision 1 (output: $RUN_OUTPUT)"
ok "Decision 1 reached"

# Look for curator_decision event with decision_type=p0_demotion AND
# action_taken referencing the oldest gap.
grep -q '"kind":"curator_decision"' "$AMB" \
  || fail "no curator_decision event emitted"
grep -q '"decision_type":"p0_demotion"' "$AMB" \
  || fail "no p0_demotion decision emitted"
ok "p0_demotion decision event present"

# In dry-run mode we expect action_taken to say "dry_run: would demote INFRA-OLDEST"
grep -q '"action_taken":"dry_run: would demote INFRA-OLDEST' "$AMB" \
  || fail "dry-run action_taken should reference INFRA-OLDEST; got: $(grep p0_demotion "$AMB")"
ok "dry-run picks INFRA-OLDEST (oldest by created_at)"

# Now re-run WITHOUT dry-run; curator should actually call `chump gap set`.
: > "$AMB"; > "$DEMOTION_LOG"
RUN_OUTPUT=$(env \
  PATH="$SHIM_DIR:$PATH" \
  CHUMP_AMBIENT_LOG="$AMB" \
  CHUMP_FLEET_STATE="$FS" \
  CHUMP_TEST_DEMOTION_LOG="$DEMOTION_LOG" \
  REPO_ROOT="$REPO_ROOT" \
  bash "$CURATOR" --once 2>&1 || true)

grep -q "DEMOTED: INFRA-OLDEST" "$DEMOTION_LOG" \
  || fail "chump gap set was NOT called for INFRA-OLDEST; log: $(cat $DEMOTION_LOG)"
ok "real run: chump gap set INFRA-OLDEST --priority P1 was invoked"

grep -q '"action_taken":"demoted INFRA-OLDEST' "$AMB" \
  || fail "real-run action_taken should say 'demoted INFRA-OLDEST'"
ok "real run: ambient event records demoted INFRA-OLDEST (not identified_only)"

# Confirm we did NOT demote the P1 gap or any of the mid/new P0s in
# a single curator run.
count=$(grep -c "DEMOTED: " "$DEMOTION_LOG")
[[ "$count" -eq 1 ]] || fail "expected exactly 1 demotion per run, got $count"
ok "max 1 demotion per curator run respected"

! grep -q "DEMOTED: INFRA-P1" "$DEMOTION_LOG" \
  || fail "P1 was incorrectly demoted (should only touch P0s)"
ok "non-P0 priorities untouched"

echo
echo "=== test-curator-p0-demotion.sh PASSED ==="
