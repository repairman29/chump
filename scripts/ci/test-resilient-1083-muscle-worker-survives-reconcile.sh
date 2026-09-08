#!/usr/bin/env bash
# scripts/ci/test-resilient-1083-muscle-worker-survives-reconcile.sh — RESILIENT-1083
#
# Proves the PERMANENT fix for the "CJ-shaped manifest" worker-orphan class:
# a non-CJ muscle node's concrete worker unit survives a role-scoped organ
# reconcile WITHOUT any per-node manifest line, while out-of-role role=brain
# organs are still reaped.
#
# ROOT BUG (mugman, 2026-09-08): scripts/ops/organ-manifest.txt was CJ-SHAPED —
# it declared chump-cj-worker.service role=muscle but the only reap-protection
# for a non-CJ muscle node's worker (chump-node1-worker.service) was a HARDCODED
# per-node manifest line (#4533). Being tracked, it was reverted by the deploy
# mirror's `git reset --hard origin/main`, which un-declared the worker and let
# organ-reconcile.sh's RESILIENT-1016 drift-removal pass reap it — the node went
# dark ~30s after the manifest reset.
#
# THE FIX (asserted here):
#   (a) organ_is_node_local() in organ-reconcile.sh now treats EVERY worker unit
#       (chump-*worker*, incl. node-orchestrator autoscale peers cj-worker2/3 and
#       the chump-worker@N template) as node-local — NEVER reaped — so no per-node
#       manifest line is needed. A brand-new muscle node's worker is safe.
#   (b) A muscle-scoped reconcile still REAPS an out-of-role role=brain organ
#       (chump-organ-watchdog.timer) that IS declared in the manifest — the
#       resurrected-brain-organ-on-a-muscle-node class the STOPGAP hand-edits
#       used to fight by commenting brain organs out of the manifest.
#   (c) The scope can be SELF-DERIVED from ~/.chump/node.env's CHUMP_NODE_ROLE
#       (which survives `git reset --hard`), not only from an explicit
#       CHUMP_ORGAN_RECONCILE_ROLE env / the systemd role drop-in.
#
# Without the fix, (a) fails (worker reaped) and (c) fails (no scoping ->
# whole-manifest -> brain organ NOT reaped).

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
RECONCILE="$REPO_ROOT/scripts/ops/organ-reconcile.sh"
LIB_MANIFEST="$REPO_ROOT/scripts/ops/lib/organ-manifest-lib.sh"
MANIFEST_REAL="$REPO_ROOT/scripts/ops/organ-manifest.txt"

fails=0
pass(){ printf '  ok   %s\n' "$*"; }
fail(){ printf '  FAIL %s\n' "$*"; fails=$((fails+1)); }

echo "=== test-resilient-1083-muscle-worker-survives-reconcile.sh (RESILIENT-1083) ==="

[[ -f "$RECONCILE" ]] || { echo "FAIL: reconcile missing: $RECONCILE"; exit 1; }
bash -n "$RECONCILE" || { echo "FAIL: reconcile bash -n"; exit 1; }
bash -n "$LIB_MANIFEST" || { echo "FAIL: lib bash -n"; exit 1; }
pass "syntax clean (reconcile + manifest lib)"

# ── 0. the real manifest no longer carries the node-specific worker line ────
if grep -qE '^enabled +chump-node1-worker\.service' "$MANIFEST_REAL"; then
  fail "real organ-manifest.txt STILL declares chump-node1-worker.service — the node-specific #4533 line must be superseded by the general node-local worker glob"
else
  pass "real organ-manifest.txt no longer carries the node-specific chump-node1-worker line (superseded #4533)"
fi

# ── 0b. organ_role_filter_for is the shared role->tags mapper ───────────────
# shellcheck source=/dev/null
source "$LIB_MANIFEST"
[[ "$(organ_role_filter_for muscle)" == "muscle" ]] || fail "organ_role_filter_for muscle should be 'muscle'"
[[ "$(organ_role_filter_for brain)" == "brain,data,janitor,trust" ]] || fail "organ_role_filter_for brain wrong: $(organ_role_filter_for brain)"
[[ -z "$(organ_role_filter_for all)" ]] || fail "organ_role_filter_for all should be empty"
[[ -z "$(organ_role_filter_for "")" ]] || fail "organ_role_filter_for '' should be empty"
pass "organ_role_filter_for maps role -> manifest role tags (muscle/brain/all)"

# ── shared stubbed-systemctl fixture (mirrors test-resilient-1016) ──────────
TMP="$(mktemp -d "${TMPDIR:-/tmp}/chump-1083.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
ACTIVE="$TMP/active.txt"; ENABLED="$TMP/enabled.txt"; UNITFILES="$TMP/unitfiles.txt"; CALLS="$TMP/calls.log"
EMPTY_STATE="$TMP/empty-state"; mkdir -p "$EMPTY_STATE"   # a state dir with NO node.env

# Live state on a non-CJ muscle node (mugman): the node-local worker + its
# autoscale peer are ABSENT from the manifest; an out-of-role brain organ and a
# node-local infra reaper are also live.
cat > "$UNITFILES" <<'EOF'
chump-node1-worker.service
chump-cj-worker2.service
chump-cj-worker.service
chump-organ-watchdog.timer
chump-cargo-target-reaper.timer
EOF
seed_live() {
  cat > "$ACTIVE" <<'EOF'
chump-node1-worker.service
chump-cj-worker2.service
chump-cj-worker.service
chump-organ-watchdog.timer
chump-cargo-target-reaper.timer
EOF
  cp "$ACTIVE" "$ENABLED"
}
seed_live

STUB="$TMP/systemctl-stub"
cat > "$STUB" <<'EOF'
#!/usr/bin/env bash
echo "$*" >> "$CALLS"
case "$1" in
  list-unit-files)
    case "$*" in
      *--type=timer*)   grep '\.timer$'   "$UNITFILES" | awk '{print $1"  enabled"}';;
      *--type=service*) grep '\.service$' "$UNITFILES" | awk '{print $1"  enabled"}';;
      *)                awk '{print $1"  enabled"}' "$UNITFILES";;
    esac
    exit 0 ;;
  is-active)  unit="${@: -1}"; grep -qxF "$unit" "$ACTIVE"  2>/dev/null && exit 0 || exit 3 ;;
  is-enabled) unit="${@: -1}"; grep -qxF "$unit" "$ENABLED" 2>/dev/null && exit 0 || exit 1 ;;
  is-failed)  echo "active"; exit 0 ;;
  enable)     unit="${@: -1}"; echo "$unit" >> "$ACTIVE"; echo "$unit" >> "$ENABLED"; exit 0 ;;
  disable)
    unit="${@: -1}"
    grep -vxF "$unit" "$ACTIVE"  > "$ACTIVE.t"  2>/dev/null; mv "$ACTIVE.t"  "$ACTIVE"
    grep -vxF "$unit" "$ENABLED" > "$ENABLED.t" 2>/dev/null; mv "$ENABLED.t" "$ENABLED"
    exit 0 ;;
  stop|daemon-reload|reset-failed) exit 0 ;;
  show) echo "ExecStart=/bin/true"; exit 0 ;;
  *) exit 0 ;;
esac
EOF
chmod +x "$STUB"

# A muscle node's manifest view: chump-cj-worker declared role=muscle (belt-and-
# suspenders, in-role), chump-organ-watchdog.timer role=brain (out-of-role). The
# node worker chump-node1-worker + peer chump-cj-worker2 are NOT declared.
MANIFEST="$TMP/organ-manifest.txt"
cat > "$MANIFEST" <<'EOF'
enabled  chump-cj-worker.service     role=muscle requires=
enabled  chump-organ-watchdog.timer  role=brain  requires=
EOF

# role-env is passed as CHUMP_ORGAN_RECONCILE_ROLE (empty string == unset for the
# reconcile's `${CHUMP_ORGAN_RECONCILE_ROLE:-}` read); statedir points the
# node.env lookup (empty-but-existing dir == no node.env). Always-set env (no
# conditional ${x:+...}) keeps this shellcheck-clean.
run_apply() {  # role-env  statedir
  local rf="$1" statedir="$2"
  : > "$CALLS"; seed_live
  env ACTIVE="$ACTIVE" ENABLED="$ENABLED" UNITFILES="$UNITFILES" CALLS="$CALLS" \
    CHUMP_ORGAN_RECONCILE_ROLE="$rf" \
    CHUMP_STATE_DIR="$statedir" \
    CHUMP_ORGAN_RECONCILE_SYSTEMCTL_BIN="$STUB" \
    CHUMP_ORGAN_RECONCILE_ALLOW_NONROOT=1 \
    CHUMP_ORGAN_RECONCILE_BACKOFF_DIR="$TMP/backoff" \
    CHUMP_ORGAN_RECONCILE_VERIFY_DELAY_S=0 \
    CHUMP_ORGAN_MANIFEST="$MANIFEST" \
    bash "$RECONCILE" --apply >/dev/null 2>&1
}
run_check() {  # role-env  statedir
  local rf="$1" statedir="$2"
  seed_live
  env ACTIVE="$ACTIVE" ENABLED="$ENABLED" UNITFILES="$UNITFILES" CALLS="$CALLS" \
    CHUMP_ORGAN_RECONCILE_ROLE="$rf" \
    CHUMP_STATE_DIR="$statedir" \
    CHUMP_ORGAN_RECONCILE_SYSTEMCTL_BIN="$STUB" \
    CHUMP_ORGAN_RECONCILE_ALLOW_NONROOT=1 \
    CHUMP_ORGAN_RECONCILE_BACKOFF_DIR="$TMP/backoff" \
    CHUMP_ORGAN_RECONCILE_VERIFY_DELAY_S=0 \
    CHUMP_ORGAN_MANIFEST="$MANIFEST" \
    bash "$RECONCILE" --check 2>&1
}

# ── 1. EXPLICIT muscle scope (CHUMP_ORGAN_RECONCILE_ROLE=muscle) ────────────
run_apply muscle "$EMPTY_STATE"
grep -q "disable --now chump-node1-worker.service" "$CALLS" \
  && fail "worker-orphan: muscle --apply must NEVER reap the node worker chump-node1-worker.service (calls: $(cat "$CALLS"))" \
  || pass "worker-orphan: muscle --apply leaves chump-node1-worker.service (absent from manifest) alone"
grep -qxF "chump-node1-worker.service" "$ACTIVE" \
  && pass "node worker still active after the drift-removal pass" \
  || fail "node worker should remain active; active: $(cat "$ACTIVE")"
grep -q "disable --now chump-cj-worker2.service" "$CALLS" \
  && fail "autoscale peer chump-cj-worker2.service must NOT be reaped (calls: $(cat "$CALLS"))" \
  || pass "node-orchestrator autoscale peer chump-cj-worker2.service is protected"
grep -q "disable --now chump-cargo-target-reaper.timer" "$CALLS" \
  && fail "node-local infra chump-cargo-target-reaper.timer must NOT be reaped (calls: $(cat "$CALLS"))" \
  || pass "node-local infra reaper is protected from drift-removal"
grep -q "disable --now chump-organ-watchdog.timer" "$CALLS" \
  && pass "out-of-role role=brain organ chump-organ-watchdog.timer IS reaped on a muscle node" \
  || fail "muscle --apply should reap the out-of-role brain organ chump-organ-watchdog.timer (calls: $(cat "$CALLS"))"
grep -qxF "chump-organ-watchdog.timer" "$ACTIVE" \
  && fail "brain organ should no longer be active after reap; active: $(cat "$ACTIVE")" \
  || pass "brain organ is no longer active after the reap"

# ── 2. --check agrees (read-only): worker not DRIFT, brain organ IS DRIFT ────
out="$(run_check muscle "$EMPTY_STATE")"
echo "$out" | grep -q "chump-node1-worker.service.*out-of-role" \
  && fail "muscle --check must NOT flag the node worker as out-of-role DRIFT; got: $out" \
  || pass "muscle --check does not flag the node worker as drift (safe reap-preview)"
echo "$out" | grep -q "DRIFT: chump-organ-watchdog.timer is active/enabled but out-of-role" \
  && pass "muscle --check flags the out-of-role brain organ as DRIFT" \
  || fail "muscle --check should flag chump-organ-watchdog.timer as DRIFT; got: $out"

# ── 3. SELF-DERIVED scope from ~/.chump/node.env (no explicit role env) ─────
# node.env survives `git reset --hard`, so it is what keeps a muscle node scoped
# when the systemd role drop-in is absent (the mugman hole).
STATEDIR="$TMP/state"; mkdir -p "$STATEDIR"
printf 'export CHUMP_NODE_ROLE=muscle\n' > "$STATEDIR/node.env"
run_apply "" "$STATEDIR"
grep -q "disable --now chump-node1-worker.service" "$CALLS" \
  && fail "self-scope: node worker must survive a node.env-derived muscle reconcile (calls: $(cat "$CALLS"))" \
  || pass "self-scope from node.env CHUMP_NODE_ROLE=muscle keeps the node worker"
grep -q "disable --now chump-organ-watchdog.timer" "$CALLS" \
  && pass "self-scope from node.env reaps the out-of-role brain organ (no explicit CHUMP_ORGAN_RECONCILE_ROLE, no drop-in needed)" \
  || fail "self-scope from node.env should reap the brain organ; calls: $(cat "$CALLS")"

# ── 4. node.env absent / role unset -> whole-manifest, no drift-removal ─────
# Back-compat: the primary (brain) node's non-scoped timer must be unchanged —
# no CHUMP_ORGAN_RECONCILE_ROLE, no node.env role -> the drift-removal pass does
# not run at all (nothing "out of role" when the whole manifest is in scope).
run_apply "" "$EMPTY_STATE"
grep -q "disable --now chump-organ-watchdog.timer" "$CALLS" \
  && fail "back-compat: with no role env and no node.env role, the drift-removal pass must NOT run (calls: $(cat "$CALLS"))" \
  || pass "back-compat: unscoped (no role env, no node.env role) reconcile skips drift-removal entirely"

echo
if [ "$fails" -eq 0 ]; then echo "PASS: RESILIENT-1083 worker-orphan permanent fix holds ($0)"; exit 0
else echo "FAIL: $fails assertion(s) failed"; exit 1; fi
