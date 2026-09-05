#!/usr/bin/env bash
# scripts/ci/test-node-install-organs-phase.sh — RESILIENT-746
#
# Regression test for the COTG node-install ORGANS-phase manifest wiring.
# Before RESILIENT-746, chump-node-install.sh's ORGANS phase stopped at two
# hand-coded organs (node-heartbeat, process-organ-heal) and NEVER installed
# the role's real organ set from scripts/ops/organ-manifest.txt — the exact
# half-built hole from the helsinki teardown. This proves two things that
# fail without the RESILIENT-746 change:
#
#   1. chump-node-install.sh's organ_role_filter() maps --role to the
#      organ-manifest.txt role= tags a node of that role should carry
#      (brain -> brain,data,janitor,trust; muscle -> muscle; all -> "").
#   2. scripts/ops/organ-reconcile.sh actually HONORS CHUMP_ORGAN_RECONCILE_ROLE
#      end-to-end: a muscle-scoped reconcile only touches role=muscle organs
#      and never attempts (or flags DRIFT on) a role=brain organ, and vice
#      versa — the mechanism reconcile_role_organs()/self_test() rely on.
#
# Network-free + deterministic: sources the installer (BASH_SOURCE guard
# prevents a real install run) to test organ_role_filter() directly, and
# drives organ-reconcile.sh --check/--apply against a synthetic manifest with
# a stubbed systemctl (mirrors scripts/ci/test-organ-reconcile.sh's harness).
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
INSTALLER="$REPO_ROOT/scripts/setup/chump-node-install.sh"
RECONCILE="$REPO_ROOT/scripts/ops/organ-reconcile.sh"
[ -f "$INSTALLER" ] || { echo "FAIL: installer not found: $INSTALLER"; exit 1; }
[ -f "$RECONCILE" ] || { echo "FAIL: reconcile script not found: $RECONCILE"; exit 1; }

fails=0
pass(){ printf '  ok   %s\n' "$*"; }
fail(){ printf '  FAIL %s\n' "$*"; fails=$((fails+1)); }

echo "=== test-node-install-organs-phase.sh (RESILIENT-746) ==="

# ── 1. organ_role_filter() maps --role to the manifest's role= tags ────────
TMP="$(mktemp -d "${TMPDIR:-/tmp}/chump-organs-phase-test.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
export CHUMP_NODE_DIR="$TMP/node"
export CHUMP_STATE_DIR="$TMP/state"
mkdir -p "$CHUMP_NODE_DIR/bin"

set --
# shellcheck disable=SC1090
. "$INSTALLER"

[ "$(ROLE=brain organ_role_filter)" = "brain,data,janitor,trust" ] \
  && pass "organ_role_filter(brain) = brain,data,janitor,trust" \
  || fail "organ_role_filter(brain) wrong (got '$(ROLE=brain organ_role_filter)')"
[ "$(ROLE=muscle organ_role_filter)" = "muscle" ] \
  && pass "organ_role_filter(muscle) = muscle" \
  || fail "organ_role_filter(muscle) wrong (got '$(ROLE=muscle organ_role_filter)')"
[ "$(ROLE=all organ_role_filter)" = "" ] \
  && pass "organ_role_filter(all) = '' (unfiltered — whole manifest)" \
  || fail "organ_role_filter(all) wrong (got '$(ROLE=all organ_role_filter)')"

# ── 2. organ-reconcile.sh --check/--apply actually HONOR the role scope ────
RTMP="$(mktemp -d)"
trap 'rm -rf "$TMP" "$RTMP"' EXIT
STATE_DIR="$RTMP/state"; mkdir -p "$STATE_DIR"
CALL_LOG="$RTMP/calls.log"
ACTIVE_FILE="$STATE_DIR/active.txt"
touch "$ACTIVE_FILE"

STUB="$RTMP/systemctl-stub"
cat > "$STUB" <<'EOF'
#!/usr/bin/env bash
echo "$*" >> "$CALL_LOG"
case "$1" in
    is-active)
        unit="${@: -1}"
        grep -qxF "$unit" "$ACTIVE_FILE" 2>/dev/null && exit 0 || exit 3
        ;;
    enable)
        unit="${@: -1}"
        echo "$unit" >> "$ACTIVE_FILE"
        exit 0
        ;;
    disable|stop|daemon-reload)
        exit 0
        ;;
    show)
        echo "ExecStart=/bin/true"
        exit 0
        ;;
    *)
        exit 0
        ;;
esac
EOF
chmod +x "$STUB"

MANIFEST="$RTMP/organ-manifest.txt"
cat > "$MANIFEST" <<'EOF'
enabled  chump-brain-organ.service   role=brain  requires=
enabled  chump-muscle-organ.service  role=muscle requires=
EOF

BACKOFF_DIR="$RTMP/organ-backoff"

run_reconcile() {  # role-filter mode
  local rf="$1" mode="$2"
  : > "$CALL_LOG"
  rm -rf "$BACKOFF_DIR"
  ACTIVE_FILE="$ACTIVE_FILE" CALL_LOG="$CALL_LOG" \
  CHUMP_ORGAN_RECONCILE_ROLE="$rf" \
  CHUMP_ORGAN_RECONCILE_SYSTEMCTL_BIN="$STUB" \
  CHUMP_ORGAN_RECONCILE_ALLOW_NONROOT=1 \
  CHUMP_ORGAN_RECONCILE_BACKOFF_DIR="$BACKOFF_DIR" \
  CHUMP_ORGAN_RECONCILE_VERIFY_DELAY_S=0 \
  CHUMP_ORGAN_MANIFEST="$MANIFEST" \
  bash "$RECONCILE" "$mode"
}

# muscle-scoped --check: only the muscle organ is down -> DRIFT on it, never
# on the brain organ (brain organ is out of scope entirely).
: > "$ACTIVE_FILE"
out="$(run_reconcile muscle --check)"
echo "$out" | grep -q "DRIFT: chump-muscle-organ.service" \
  || fail "muscle-scoped --check should flag DRIFT on the muscle organ; got: $out"
echo "$out" | grep -q "chump-brain-organ.service" \
  && fail "muscle-scoped --check must not mention the brain organ at all; got: $out" \
  || pass "muscle-scoped --check only evaluates role=muscle organs (brain organ out of scope)"

# muscle-scoped --apply: only the muscle organ is ever enabled; the brain
# organ is never touched (proves the role filter, not just reporting, gates
# which organs the reconcile acts on).
: > "$ACTIVE_FILE"
run_reconcile muscle --apply >/dev/null
grep -q "enable --now chump-muscle-organ.service" "$CALL_LOG" \
  || fail "muscle-scoped --apply should enable the muscle organ; calls: $(cat "$CALL_LOG")"
grep -q "chump-brain-organ.service" "$CALL_LOG" \
  && fail "muscle-scoped --apply must NEVER touch the brain organ; calls: $(cat "$CALL_LOG")" \
  || pass "muscle-scoped --apply enables only role=muscle organs, never role=brain"

# brain-scoped --check: symmetric — only the brain organ is in scope.
: > "$ACTIVE_FILE"
out="$(run_reconcile brain --check)"
echo "$out" | grep -q "DRIFT: chump-brain-organ.service" \
  || fail "brain-scoped --check should flag DRIFT on the brain organ; got: $out"
echo "$out" | grep -q "chump-muscle-organ.service" \
  && fail "brain-scoped --check must not mention the muscle organ; got: $out" \
  || pass "brain-scoped --check only evaluates role=brain organs (muscle organ out of scope)"

# unfiltered (--role all -> empty filter) --check: BOTH organs are evaluated.
: > "$ACTIVE_FILE"
out="$(run_reconcile "" --check)"
echo "$out" | grep -q "DRIFT: chump-brain-organ.service" && echo "$out" | grep -q "DRIFT: chump-muscle-organ.service" \
  && pass "unfiltered (role=all) --check evaluates the WHOLE manifest, both organs" \
  || fail "unfiltered --check should flag DRIFT on both organs; got: $out"

echo
if [ "$fails" -eq 0 ]; then echo "PASS: ORGANS-phase manifest wiring holds ($0)"; exit 0
else echo "FAIL: $fails assertion(s) failed"; exit 1; fi
