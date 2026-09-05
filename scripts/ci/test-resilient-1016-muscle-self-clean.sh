#!/usr/bin/env bash
# scripts/ci/test-resilient-1016-muscle-self-clean.sh — RESILIENT-1016
#
# Proves the two durable fixes for "muscle node not 0-failed after a
# --role muscle install" (VERIFIED on mugman: 64 active but worker DOWN +
# failures):
#
#   (a) organ-reconcile.sh's role-scoped reconcile now has a drift-REMOVAL
#       pass: an active/enabled chump unit that is NOT in the role-filtered
#       manifest gets disable --now + reset-failed instead of persisting
#       forever. Both --check (reports DRIFT) and --apply (actually reaps)
#       are exercised against a stubbed systemctl.
#
#   (b) chump-node-install.sh's install_organs() now MATERIALIZES
#       $ORGAN_DIR/worker.sh for a muscle (or all) role install — before this
#       fix, muscle_organs() declared a "worker" organ whose exec pointed at
#       a script that was never written, so the systemd unit installed but
#       could never go active.
#
# Both assertions FAIL without the RESILIENT-1016 change.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
RECONCILE="$REPO_ROOT/scripts/ops/organ-reconcile.sh"
INSTALLER="$REPO_ROOT/scripts/setup/chump-node-install.sh"

[[ -f "$RECONCILE" ]] || { echo "FAIL: reconcile script missing: $RECONCILE"; exit 1; }
[[ -f "$INSTALLER" ]] || { echo "FAIL: installer missing: $INSTALLER"; exit 1; }

fails=0
pass(){ printf '  ok   %s\n' "$*"; }
fail(){ printf '  FAIL %s\n' "$*"; fails=$((fails+1)); }

echo "=== test-resilient-1016-muscle-self-clean.sh (RESILIENT-1016) ==="

# ── (a) drift-REMOVAL pass in organ-reconcile.sh ────────────────────────────
RTMP="$(mktemp -d "${TMPDIR:-/tmp}/chump-1016-reconcile-test.XXXXXX")"
trap 'rm -rf "$RTMP"' EXIT

# Live-state files the stub consults/mutates:
ACTIVE_FILE="$RTMP/active.txt"      # units systemctl considers active
ENABLED_FILE="$RTMP/enabled.txt"    # units systemctl considers enabled
UNITFILES_FILE="$RTMP/unitfiles.txt"  # every chump-*.service unit FILE present
CALL_LOG="$RTMP/calls.log"

# Scenario: mugman after a role=brain -> role=muscle switch. 28-unit incident
# is simulated with 2 stray out-of-role units (brain + a manifest-orphan) plus
# the in-role muscle unit that must stay untouched.
cat > "$UNITFILES_FILE" <<'EOF'
chump-muscle-organ.service
chump-brain-organ.service
chump-orphan-organ.service
EOF
cat > "$ACTIVE_FILE" <<'EOF'
chump-muscle-organ.service
chump-brain-organ.service
chump-orphan-organ.service
EOF
cat > "$ENABLED_FILE" <<'EOF'
chump-muscle-organ.service
chump-brain-organ.service
chump-orphan-organ.service
EOF

STUB="$RTMP/systemctl-stub"
cat > "$STUB" <<'EOF'
#!/usr/bin/env bash
echo "$*" >> "$CALL_LOG"
case "$1" in
    list-unit-files)
        cat "$UNITFILES_FILE" | awk '{print $1"  enabled"}'
        exit 0
        ;;
    is-active)
        unit="${@: -1}"
        grep -qxF "$unit" "$ACTIVE_FILE" 2>/dev/null && exit 0 || exit 3
        ;;
    is-enabled)
        unit="${@: -1}"
        grep -qxF "$unit" "$ENABLED_FILE" 2>/dev/null && exit 0 || exit 1
        ;;
    enable)
        unit="${@: -1}"
        echo "$unit" >> "$ACTIVE_FILE"
        echo "$unit" >> "$ENABLED_FILE"
        exit 0
        ;;
    disable)
        unit="${@: -1}"
        grep -vxF "$unit" "$ACTIVE_FILE" > "$ACTIVE_FILE.tmp" 2>/dev/null; mv "$ACTIVE_FILE.tmp" "$ACTIVE_FILE"
        grep -vxF "$unit" "$ENABLED_FILE" > "$ENABLED_FILE.tmp" 2>/dev/null; mv "$ENABLED_FILE.tmp" "$ENABLED_FILE"
        exit 0
        ;;
    stop|daemon-reload|reset-failed)
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
enabled  chump-muscle-organ.service  role=muscle requires=
enabled  chump-brain-organ.service   role=brain  requires=
EOF
# NOTE: chump-orphan-organ.service is deliberately absent from the manifest —
# it simulates a unit dropped from the manifest entirely.

BACKOFF_DIR="$RTMP/organ-backoff"

run_reconcile() {  # role-filter mode
    local rf="$1" mode="$2"
    : > "$CALL_LOG"
    rm -rf "$BACKOFF_DIR"
    ACTIVE_FILE="$ACTIVE_FILE" ENABLED_FILE="$ENABLED_FILE" UNITFILES_FILE="$UNITFILES_FILE" CALL_LOG="$CALL_LOG" \
    CHUMP_ORGAN_RECONCILE_ROLE="$rf" \
    CHUMP_ORGAN_RECONCILE_SYSTEMCTL_BIN="$STUB" \
    CHUMP_ORGAN_RECONCILE_ALLOW_NONROOT=1 \
    CHUMP_ORGAN_RECONCILE_BACKOFF_DIR="$BACKOFF_DIR" \
    CHUMP_ORGAN_RECONCILE_VERIFY_DELAY_S=0 \
    CHUMP_ORGAN_MANIFEST="$MANIFEST" \
    bash "$RECONCILE" "$mode"
}

# muscle-scoped --check: flags DRIFT on both out-of-role units, never on the
# in-role muscle unit (which is already active).
out="$(run_reconcile muscle --check)"
echo "$out" | grep -q "DRIFT: chump-brain-organ.service is active/enabled but out-of-role" \
    && pass "muscle-scoped --check flags the out-of-role brain unit as DRIFT" \
    || fail "muscle-scoped --check should flag chump-brain-organ.service; got: $out"
echo "$out" | grep -q "DRIFT: chump-orphan-organ.service is active/enabled but out-of-role" \
    && pass "muscle-scoped --check flags the manifest-orphan unit as DRIFT" \
    || fail "muscle-scoped --check should flag chump-orphan-organ.service; got: $out"
echo "$out" | grep -q "chump-muscle-organ.service.*DRIFT\|DRIFT.*chump-muscle-organ.service" \
    && fail "muscle-scoped --check must not flag the in-role, already-active muscle unit; got: $out" \
    || pass "muscle-scoped --check leaves the in-role muscle unit alone"

# muscle-scoped --apply: actually disables + reaps both out-of-role units,
# never touches the in-role muscle unit.
cat > "$ACTIVE_FILE" <<'EOF'
chump-muscle-organ.service
chump-brain-organ.service
chump-orphan-organ.service
EOF
cat > "$ENABLED_FILE" <<'EOF'
chump-muscle-organ.service
chump-brain-organ.service
chump-orphan-organ.service
EOF
run_reconcile muscle --apply >/dev/null
grep -q "disable --now chump-brain-organ.service" "$CALL_LOG" \
    && pass "muscle-scoped --apply disables the out-of-role brain unit" \
    || fail "muscle-scoped --apply should disable chump-brain-organ.service; calls: $(cat "$CALL_LOG")"
grep -q "disable --now chump-orphan-organ.service" "$CALL_LOG" \
    && pass "muscle-scoped --apply disables the manifest-orphan unit" \
    || fail "muscle-scoped --apply should disable chump-orphan-organ.service; calls: $(cat "$CALL_LOG")"
grep -q "reset-failed chump-brain-organ.service" "$CALL_LOG" \
    && grep -q "reset-failed chump-orphan-organ.service" "$CALL_LOG" \
    && pass "muscle-scoped --apply reset-failed's both reaped units" \
    || fail "muscle-scoped --apply should reset-failed both stray units; calls: $(cat "$CALL_LOG")"
grep -q "disable --now chump-muscle-organ.service" "$CALL_LOG" \
    && fail "muscle-scoped --apply must NEVER disable the in-role muscle unit; calls: $(cat "$CALL_LOG")" \
    || pass "muscle-scoped --apply never touches the in-role muscle unit"
grep -qxF "chump-muscle-organ.service" "$ACTIVE_FILE" \
    && pass "in-role muscle unit is still active after the drift-removal pass" \
    || fail "in-role muscle unit should remain active; active file: $(cat "$ACTIVE_FILE")"
grep -qxF "chump-brain-organ.service" "$ACTIVE_FILE" \
    && fail "out-of-role brain unit should no longer be active; active file: $(cat "$ACTIVE_FILE")" \
    || pass "out-of-role brain unit is no longer active"

# unfiltered (role=all -> empty filter) --apply: drift-removal pass does NOT
# run at all — nothing "out of role" when the whole manifest is in scope.
cat > "$ACTIVE_FILE" <<'EOF'
chump-muscle-organ.service
chump-brain-organ.service
chump-orphan-organ.service
EOF
cat > "$ENABLED_FILE" <<'EOF'
chump-muscle-organ.service
chump-brain-organ.service
chump-orphan-organ.service
EOF
run_reconcile "" --apply >/dev/null
grep -q "disable --now chump-orphan-organ.service" "$CALL_LOG" \
    && fail "unfiltered (role=all) --apply must not run the drift-removal pass; calls: $(cat "$CALL_LOG")" \
    || pass "unfiltered (role=all) --apply skips the drift-removal pass entirely (whole manifest already in scope)"

# ── (b) chump-node-install.sh materializes $ORGAN_DIR/worker.sh for muscle ──
# Drives the REAL install_organs() (not a reproduction) against a scratch
# NODE_DIR — svc_install will fail to write /etc/systemd/system (non-root,
# expected/harmless here; we only assert on the organ script it materializes
# on disk before ever touching systemd).
ITMP="$(mktemp -d "${TMPDIR:-/tmp}/chump-1016-install-test.XXXXXX")"
trap 'rm -rf "$RTMP" "$ITMP"' EXIT
export CHUMP_NODE_DIR="$ITMP/node"
export CHUMP_STATE_DIR="$ITMP/state"
mkdir -p "$CHUMP_NODE_DIR/bin" "$CHUMP_NODE_DIR/organs" "$CHUMP_NODE_DIR/logs"

(
    set --
    # shellcheck disable=SC1090
    . "$INSTALLER"
    ROLE=muscle
    detect_host
    install_organs
) >"$ITMP/install.log" 2>&1

if [ -f "$CHUMP_NODE_DIR/organs/worker.sh" ]; then
    pass "worker.sh materializes on disk for a muscle-role install"
else
    fail "worker.sh should exist at $CHUMP_NODE_DIR/organs/worker.sh after a muscle install (install.log: $(cat "$ITMP/install.log"))"
fi
if [ -x "$CHUMP_NODE_DIR/organs/worker.sh" ]; then
    pass "worker.sh is executable"
else
    fail "worker.sh should be chmod +x"
fi
grep -q 'scripts/dispatch/worker.sh' "$CHUMP_NODE_DIR/organs/worker.sh" 2>/dev/null \
    && pass "worker.sh execs the tracked scripts/dispatch/worker.sh (the real fleet worker loop)" \
    || fail "worker.sh should exec scripts/dispatch/worker.sh"

# ── (b2) a brain-role install must NOT materialize worker.sh at all ────────
BTMP="$(mktemp -d "${TMPDIR:-/tmp}/chump-1016-install-brain-test.XXXXXX")"
trap 'rm -rf "$RTMP" "$ITMP" "$BTMP"' EXIT
export CHUMP_NODE_DIR="$BTMP/node"
export CHUMP_STATE_DIR="$BTMP/state"
mkdir -p "$CHUMP_NODE_DIR/bin" "$CHUMP_NODE_DIR/organs" "$CHUMP_NODE_DIR/logs"
(
    set --
    # shellcheck disable=SC1090
    . "$INSTALLER"
    ROLE=brain
    detect_host
    install_organs
) >"$BTMP/install.log" 2>&1
if [ -f "$CHUMP_NODE_DIR/organs/worker.sh" ]; then
    fail "a brain-role install should NOT materialize worker.sh"
else
    pass "a brain-role install correctly skips materializing worker.sh"
fi

echo
if [ "$fails" -eq 0 ]; then echo "PASS: muscle self-clean + worker self-start hold ($0)"; exit 0
else echo "FAIL: $fails assertion(s) failed"; exit 1; fi
